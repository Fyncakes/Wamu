"""Payment service — idempotent initiation + webhook processing."""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from decimal import Decimal

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.integrations.payments.provider import get_payment_provider
from app.core.metrics import (
    PAYMENT_FAILED,
    PAYMENT_INITIATED,
    PAYMENT_SUCCESS,
    metrics,
)
from app.models.audit import AuditLog
from app.models.notification import Notification
from app.models.order import Order, OrderStatus
from app.models.payment import Payment, PaymentStatus, PaymentWebhookEvent
from app.models.user import User
from app.schemas.commerce import PaymentCreate, WebhookPayload
from app.services.order import get_order


async def finalize_payment_success(
    db: AsyncSession,
    payment: Payment,
    *,
    audit_action: str = "PAYMENT_SUCCESS",
    notify_customer: bool = True,
) -> Order:
    """Side effects after payment becomes SUCCESS (stock, delivery, cards, payout).

    Caller must set payment.status = SUCCESS and ensure this runs only on the
    PENDING/PROCESSING → SUCCESS transition (not on already-success rows).
    """
    metrics.incr(PAYMENT_SUCCESS)
    order = await get_order(db, payment.order_id)
    if order.status == OrderStatus.PENDING.value:
        order.status = OrderStatus.CONFIRMED.value
        order.version += 1

    if notify_customer:
        db.add(
            Notification(
                user_id=payment.user_id,
                type="PAYMENT_SUCCESS",
                title="Payment successful",
                body=f"Paid UGX {payment.amount}",
                data={"payment_id": str(payment.id), "order_id": str(order.id)},
            )
        )
    db.add(
        AuditLog(
            actor_id=payment.user_id,
            action=audit_action,
            entity_type="payment",
            entity_id=payment.id,
            metadata_json={"amount": str(payment.amount), "provider": payment.provider},
        )
    )

    from app.services.order import (
        commit_order_stock,
        notify_merchant_order_paid,
        refresh_order_cards_after_payment,
    )
    from app.services.payout import enqueue_payout_for_payment
    from app.services.riders import ensure_delivery_for_paid_order

    await commit_order_stock(db, order)
    await enqueue_payout_for_payment(db, payment)
    await ensure_delivery_for_paid_order(db, order)
    await db.refresh(order, attribute_names=["payment"])
    await refresh_order_cards_after_payment(db, order)
    await notify_merchant_order_paid(db, order)
    await db.flush()
    return order


async def initiate_payment(db: AsyncSession, user: User, data: PaymentCreate) -> Payment:
    # Idempotency: return existing payment for same user+key
    existing = await db.scalar(
        select(Payment).where(
            Payment.user_id == user.id, Payment.idempotency_key == data.idempotency_key
        )
    )
    if existing:
        if existing.order_id != data.order_id:
            raise HTTPException(
                status_code=409,
                detail="Idempotency key already used for a different order",
            )
        return existing

    order = await get_order(db, data.order_id)
    if order.customer_id != user.id:
        raise HTTPException(status_code=403, detail="Not your order")
    if order.status == OrderStatus.CANCELLED.value:
        raise HTTPException(status_code=400, detail="Order cancelled")

    existing_order_pay = await db.scalar(select(Payment).where(Payment.order_id == order.id))
    if existing_order_pay and existing_order_pay.status == PaymentStatus.SUCCESS.value:
        raise HTTPException(status_code=400, detail="Order already paid")
    # One payment row per order — return in-flight attempts; re-use FAILED for retry.
    if existing_order_pay and existing_order_pay.status != PaymentStatus.FAILED.value:
        return existing_order_pay

    provider = get_payment_provider(data.provider)
    if existing_order_pay is not None:
        payment = existing_order_pay
        payment.provider = provider.name
        payment.idempotency_key = data.idempotency_key
        payment.phone = data.phone or user.phone or payment.phone
        payment.status = PaymentStatus.PENDING.value
        payment.provider_reference = None
        payment.raw_response = None
        payment.amount = order.total
    else:
        payment = Payment(
            order_id=order.id,
            user_id=user.id,
            amount=order.total,
            currency=order.currency,
            provider=provider.name,
            idempotency_key=data.idempotency_key,
            phone=data.phone or user.phone,
            status=PaymentStatus.PENDING.value,
        )
        db.add(payment)
    try:
        await db.flush()
    except IntegrityError:
        # Race: concurrent create with same idempotency_key — re-select like chat.
        await db.rollback()
        raced = await db.scalar(
            select(Payment).where(
                Payment.user_id == user.id, Payment.idempotency_key == data.idempotency_key
            )
        )
        if raced:
            if raced.order_id != data.order_id:
                raise HTTPException(
                    status_code=409,
                    detail="Idempotency key already used for a different order",
                )
            return raced
        raise HTTPException(status_code=409, detail="Duplicate payment")

    metrics.incr(PAYMENT_INITIATED)
    try:
        result = await provider.initiate_payment(
            amount=payment.amount,
            currency=payment.currency,
            reference=str(payment.id),
            phone=payment.phone,
        )
    except RuntimeError as exc:
        payment.status = PaymentStatus.FAILED.value
        await db.flush()
        metrics.incr(PAYMENT_FAILED)
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except NotImplementedError as exc:
        payment.status = PaymentStatus.FAILED.value
        await db.flush()
        raise HTTPException(status_code=501, detail=str(exc)) from exc
    payment.provider_reference = result.provider_reference
    payment.raw_response = result.raw
    payment.status = (
        PaymentStatus.SUCCESS.value
        if result.status == "SUCCESS"
        else PaymentStatus.PROCESSING.value
    )

    if payment.status == PaymentStatus.SUCCESS.value:
        await finalize_payment_success(db, payment)
    await db.flush()
    return payment


async def process_webhook(db: AsyncSession, provider: str, payload: WebhookPayload) -> dict:
    # Deduplicate webhook events
    existing = await db.scalar(
        select(PaymentWebhookEvent).where(
            PaymentWebhookEvent.provider == provider,
            PaymentWebhookEvent.event_id == payload.event_id,
        )
    )
    if existing and existing.processed_at:
        return {"status": "duplicate", "event_id": payload.event_id}

    event = existing or PaymentWebhookEvent(
        provider=provider,
        event_id=payload.event_id,
        payload=payload.model_dump(mode="json"),
    )
    if not existing:
        db.add(event)
        await db.flush()

    payment = await db.scalar(
        select(Payment).where(
            Payment.provider == provider.upper(),
            Payment.provider_reference == payload.provider_reference,
        )
    )
    if not payment:
        # May be a disbursement callback for merchant payout
        from app.services.payout import process_payout_webhook

        return await process_payout_webhook(db, provider.upper(), payload)

    # Amount verification when provider sends amount
    if payload.amount is not None and Decimal(payload.amount) != payment.amount:
        event.notes = "Amount mismatch"
        event.processed_at = datetime.now(timezone.utc)
        await db.flush()
        raise HTTPException(status_code=400, detail="Amount mismatch")

    # Successful payments are immutable
    if payment.status == PaymentStatus.SUCCESS.value:
        event.processed_at = datetime.now(timezone.utc)
        await db.flush()
        return {"status": "already_success"}

    if payload.status.upper() == "SUCCESS":
        payment.status = PaymentStatus.SUCCESS.value
        await finalize_payment_success(db, payment, notify_customer=False)
    elif payload.status.upper() == "FAILED":
        payment.status = PaymentStatus.FAILED.value
        metrics.incr(PAYMENT_FAILED)
    else:
        payment.status = PaymentStatus.PROCESSING.value

    event.processed_at = datetime.now(timezone.utc)
    await db.flush()
    return {"status": "processed", "payment_status": payment.status}


async def refresh_payment(db: AsyncSession, payment_id: uuid.UUID, user: User) -> Payment:
    """Client poll: ask provider for current status and finalize if SUCCESS."""
    payment = await get_payment(db, payment_id, user)
    if payment.status == PaymentStatus.SUCCESS.value:
        return payment
    if payment.status == PaymentStatus.FAILED.value:
        return payment
    if not payment.provider_reference:
        return payment

    provider = get_payment_provider(payment.provider)
    try:
        status_result = await provider.check_status(payment.provider_reference)
    except Exception as exc:
        raise HTTPException(status_code=503, detail=f"Provider status check failed: {exc}") from exc

    payment.raw_response = {
        **(payment.raw_response or {}),
        "client_refresh": status_result.raw,
        "refreshed_at": datetime.now(timezone.utc).isoformat(),
    }
    new_status = (status_result.status or "").upper()
    if new_status == "SUCCESS":
        payment.status = PaymentStatus.SUCCESS.value
        await finalize_payment_success(
            db, payment, audit_action="PAYMENT_REFRESH_SUCCESS"
        )
    elif new_status == "FAILED":
        payment.status = PaymentStatus.FAILED.value
        metrics.incr(PAYMENT_FAILED)
    elif new_status in {"PENDING", "PROCESSING"}:
        payment.status = PaymentStatus.PROCESSING.value
    await db.flush()
    return payment


async def get_payment(db: AsyncSession, payment_id: uuid.UUID, user: User) -> Payment:
    payment = await db.get(Payment, payment_id)
    if not payment:
        raise HTTPException(status_code=404, detail="Payment not found")
    if payment.user_id != user.id and user.role != "ADMIN":
        raise HTTPException(status_code=403, detail="Forbidden")
    return payment


async def attempt_collection_refund(
    db: AsyncSession,
    payment: Payment,
    *,
    reason: str,
) -> dict:
    """Refund via provider when available; always update ledger.

    Live MTN/Airtel refund APIs are not fully wired — on NotImplementedError or
    rail failure we still mark REFUNDED for order/stock flow but flag
    ``manual_required`` so ops can reverse MoMo float outside the app.
    """
    import logging

    logger = logging.getLogger(__name__)
    rail_ok = False
    detail: str | None = None
    try:
        provider = get_payment_provider(payment.provider)
        ref = payment.provider_reference or str(payment.id)
        result = await provider.refund(ref)
        rail_ok = True
        detail = getattr(result, "status", None) or "REFUNDED"
    except NotImplementedError as exc:
        logger.warning(
            "Provider %s has no live refund API — ledger refund only (payment=%s): %s",
            payment.provider,
            payment.id,
            exc,
        )
        detail = "manual_refund_required"
    except Exception as exc:
        logger.exception(
            "Provider refund failed for payment %s (%s)", payment.id, payment.provider
        )
        detail = f"refund_error:{exc}"

    meta = {
        "rail_completed": rail_ok,
        "manual_required": not rail_ok,
        "detail": detail,
        "reason": reason,
        "at": datetime.now(timezone.utc).isoformat(),
    }
    payment.raw_response = {**(payment.raw_response or {}), "refund": meta}
    payment.status = PaymentStatus.REFUNDED.value

    if not rail_ok:
        db.add(
            AuditLog(
                actor_id=None,
                action="PAYMENT_MANUAL_REFUND_REQUIRED",
                entity_type="payment",
                entity_id=payment.id,
                metadata_json={
                    "provider": payment.provider,
                    "reason": reason,
                    "detail": detail,
                    "amount": str(payment.amount),
                },
            )
        )
    await db.flush()
    return meta
