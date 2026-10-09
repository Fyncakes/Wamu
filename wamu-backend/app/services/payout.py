"""Merchant payout service — enqueue after collection SUCCESS; process disbursement webhooks."""

from __future__ import annotations

import logging
import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal, ROUND_DOWN

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.metrics import PAYOUT_FAILED, PAYOUT_INITIATED, PAYOUT_SUCCESS, metrics
from app.integrations.payments.disbursement import get_disbursement_provider
from app.models.audit import AuditLog
from app.models.business import Business
from app.models.notification import Notification
from app.models.order import Order
from app.models.payment import Payment, PaymentStatus, PaymentWebhookEvent
from app.models.payout import MerchantPayout, PayoutStatus
from app.models.user import User
from app.schemas.commerce import WebhookPayload

logger = logging.getLogger(__name__)


def resolve_payee_phone(business: Business, owner: User | None) -> str | None:
    return business.payout_phone or business.phone or (owner.phone if owner else None)


def resolve_payout_provider(business: Business, payment: Payment) -> str:
    if business.payout_provider:
        return business.payout_provider.upper()
    # Prefer same rail as collection when possible
    if payment.provider in {"MTN", "AIRTEL", "MOCK"}:
        return payment.provider
    return "MOCK"


def compute_platform_fee(gross: Decimal, fee_bps: int | None = None) -> tuple[Decimal, Decimal, int]:
    """
    Split collection into (net_to_merchant, platform_fee, bps).
    Fee is ROUND_DOWN to the UGX cent; never creates a Wamu wallet balance.
    """
    bps = get_settings().platform_fee_bps if fee_bps is None else int(fee_bps)
    if bps < 0:
        bps = 0
    if bps == 0 or gross <= 0:
        return gross, Decimal("0.00"), 0
    fee = (gross * Decimal(bps) / Decimal(10000)).quantize(
        Decimal("0.01"), rounding=ROUND_DOWN
    )
    net = (gross - fee).quantize(Decimal("0.01"), rounding=ROUND_DOWN)
    if net <= 0:
        # Degenerate tiny order — refuse fee rather than zero out merchant
        return gross, Decimal("0.00"), 0
    return net, fee, bps


async def reverse_payout_for_payment(
    db: AsyncSession, payment: Payment, *, reason: str = "order_cancelled"
) -> MerchantPayout | None:
    """Mark merchant payout reversed/failed when collection is refunded.

    Live MoMo disbursement reverse APIs are not wired — SUCCESS rows become
    REVERSED for ops ledger; open PENDING/PROCESSING rows are FAILED so they
    will not disburse. Pair with attempt_collection_refund which flags
    PAYMENT_MANUAL_REFUND_REQUIRED when the collection rail cannot auto-refund.
    """
    payout = await db.scalar(
        select(MerchantPayout).where(MerchantPayout.payment_id == payment.id)
    )
    if payout is None:
        return None
    if payout.status == PayoutStatus.REVERSED.value:
        return payout
    if payout.status == PayoutStatus.SUCCESS.value:
        payout.status = PayoutStatus.REVERSED.value
        payout.raw_response = {
            **(payout.raw_response or {}),
            "reversed_reason": reason,
        }
    elif payout.status in {
        PayoutStatus.PENDING.value,
        PayoutStatus.PROCESSING.value,
    }:
        payout.status = PayoutStatus.FAILED.value
        payout.raw_response = {
            **(payout.raw_response or {}),
            "cancelled_reason": reason,
        }
    else:
        return payout

    db.add(
        AuditLog(
            actor_id=None,
            action="PAYOUT_REVERSED",
            entity_type="merchant_payout",
            entity_id=payout.id,
            metadata_json={
                "reason": reason,
                "payment_id": str(payment.id),
                "order_id": str(payout.order_id),
                "status": payout.status,
            },
        )
    )
    business = await db.get(Business, payout.business_id)
    if business:
        db.add(
            Notification(
                user_id=business.owner_id,
                type="PAYOUT_REVERSED",
                title="Payout reversed",
                body=f"Payout for order was reversed ({reason.replace('_', ' ')})",
                data={
                    "payout_id": str(payout.id),
                    "order_id": str(payout.order_id),
                    "payment_id": str(payment.id),
                    "audience": "merchant",
                },
            )
        )
    await db.flush()
    return payout


async def enqueue_payout_for_payment(
    db: AsyncSession, payment: Payment
) -> MerchantPayout | None:
    """
    Create + initiate a merchant payout for a SUCCESS collection.
    Idempotent on payment_id. Returns existing row if already created.
    Disburses net of PLATFORM_FEE_BPS; fee remains in MoMo float (non-custodial).
    """
    if payment.status != PaymentStatus.SUCCESS.value:
        return None

    existing = await db.scalar(
        select(MerchantPayout).where(MerchantPayout.payment_id == payment.id)
    )
    if existing:
        return existing

    order = await db.get(Order, payment.order_id)
    if not order:
        logger.warning("Payout skipped — order missing payment_id=%s", payment.id)
        return None

    business = await db.get(Business, order.business_id)
    if not business:
        logger.warning("Payout skipped — business missing order_id=%s", order.id)
        return None

    owner = await db.get(User, business.owner_id)
    payee = resolve_payee_phone(business, owner)
    if not payee:
        logger.warning(
            "Payout deferred — no payout phone business_id=%s payment_id=%s",
            business.id,
            payment.id,
        )
        db.add(
            AuditLog(
                actor_id=business.owner_id,
                action="PAYOUT_SKIPPED_NO_PHONE",
                entity_type="payment",
                entity_id=payment.id,
                metadata_json={"business_id": str(business.id)},
            )
        )
        await db.flush()
        return None

    provider_name = resolve_payout_provider(business, payment)
    net, fee, bps = compute_platform_fee(Decimal(payment.amount))
    payout = MerchantPayout(
        payment_id=payment.id,
        order_id=order.id,
        business_id=business.id,
        amount=net,
        platform_fee=fee,
        fee_bps=bps,
        currency=payment.currency,
        provider=provider_name,
        idempotency_key=f"payout-{payment.id}",
        payee_phone=payee,
        status=PayoutStatus.PENDING.value,
    )
    try:
        async with db.begin_nested():
            db.add(payout)
            await db.flush()
    except IntegrityError:
        return await db.scalar(
            select(MerchantPayout).where(MerchantPayout.payment_id == payment.id)
        )

    metrics.incr(PAYOUT_INITIATED)
    return await _initiate_disbursement(db, payout)


async def _initiate_disbursement(
    db: AsyncSession, payout: MerchantPayout
) -> MerchantPayout:
    if payout.status == PayoutStatus.SUCCESS.value:
        return payout
    try:
        provider = get_disbursement_provider(payout.provider)
        result = await provider.initiate_disbursement(
            amount=payout.amount,
            currency=payout.currency,
            reference=str(payout.id),
            payee_phone=payout.payee_phone,
        )
    except RuntimeError as exc:
        payout.status = PayoutStatus.FAILED.value
        payout.raw_response = {"error": str(exc)}
        metrics.incr(PAYOUT_FAILED)
        await db.flush()
        return payout
    except Exception as exc:
        logger.exception("Disbursement initiate failed payout_id=%s", payout.id)
        payout.status = PayoutStatus.PENDING.value
        payout.raw_response = {"error": str(exc)}
        await db.flush()
        return payout

    payout.provider_reference = result.provider_reference
    payout.raw_response = result.raw
    if result.status == "SUCCESS":
        payout.status = PayoutStatus.SUCCESS.value
        metrics.incr(PAYOUT_SUCCESS)
        await _notify_payout_success(db, payout)
    elif result.status == "FAILED":
        payout.status = PayoutStatus.FAILED.value
        metrics.incr(PAYOUT_FAILED)
    else:
        payout.status = PayoutStatus.PROCESSING.value
    await db.flush()
    return payout


async def _notify_payout_success(db: AsyncSession, payout: MerchantPayout) -> None:
    business = await db.get(Business, payout.business_id)
    if not business:
        return
    db.add(
        Notification(
            user_id=business.owner_id,
            type="PAYOUT_SUCCESS",
            title="Payout sent",
            body=f"UGX {payout.amount} sent to {payout.payee_phone}",
            data={
                "payout_id": str(payout.id),
                "payment_id": str(payout.payment_id),
                "order_id": str(payout.order_id),
                "platform_fee": str(payout.platform_fee),
                "fee_bps": payout.fee_bps,
            },
        )
    )
    db.add(
        AuditLog(
            actor_id=business.owner_id,
            action="PAYOUT_SUCCESS",
            entity_type="merchant_payout",
            entity_id=payout.id,
            metadata_json={
                "amount": str(payout.amount),
                "platform_fee": str(payout.platform_fee),
                "fee_bps": payout.fee_bps,
                "provider": payout.provider,
                "payee": payout.payee_phone,
            },
        )
    )


async def process_payout_webhook(
    db: AsyncSession, provider: str, payload: WebhookPayload
) -> dict:
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
        payload={**(payload.model_dump(mode="json")), "kind": "disbursement"},
    )
    if not existing:
        db.add(event)
        await db.flush()

    payout = await db.scalar(
        select(MerchantPayout).where(
            MerchantPayout.provider == provider.upper(),
            MerchantPayout.provider_reference == payload.provider_reference,
        )
    )
    if not payout:
        event.notes = "Payout not found"
        event.processed_at = datetime.now(timezone.utc)
        await db.flush()
        return {"status": "ignored", "reason": "payout_not_found"}

    if payload.amount is not None and Decimal(payload.amount) != payout.amount:
        event.notes = "Amount mismatch"
        event.processed_at = datetime.now(timezone.utc)
        await db.flush()
        raise HTTPException(status_code=400, detail="Amount mismatch")

    if payout.status == PayoutStatus.SUCCESS.value:
        event.processed_at = datetime.now(timezone.utc)
        await db.flush()
        return {"status": "already_success"}

    if payload.status.upper() == "SUCCESS":
        payout.status = PayoutStatus.SUCCESS.value
        metrics.incr(PAYOUT_SUCCESS)
        await _notify_payout_success(db, payout)
    elif payload.status.upper() == "FAILED":
        payout.status = PayoutStatus.FAILED.value
        metrics.incr(PAYOUT_FAILED)
    else:
        payout.status = PayoutStatus.PROCESSING.value

    event.processed_at = datetime.now(timezone.utc)
    await db.flush()
    return {"status": "processed", "payout_status": payout.status}


async def reconcile_pending_payouts(
    db: AsyncSession,
    *,
    stale_hours: int = 24,
    limit: int = 50,
) -> dict:
    open_statuses = {PayoutStatus.PENDING.value, PayoutStatus.PROCESSING.value}
    result = await db.execute(
        select(MerchantPayout)
        .where(MerchantPayout.status.in_(open_statuses))
        .order_by(MerchantPayout.created_at.asc())
        .limit(limit)
    )
    payouts = list(result.scalars().all())
    checked = updated = expired = errors = 0
    now = datetime.now(timezone.utc)
    cutoff = now - timedelta(hours=stale_hours)

    for payout in payouts:
        checked += 1
        try:
            if payout.provider_reference:
                provider = get_disbursement_provider(payout.provider)
                status_result = await provider.check_status(payout.provider_reference)
                new_status = (status_result.status or "").upper()
                payout.raw_response = {
                    **(payout.raw_response or {}),
                    "reconcile": status_result.raw,
                    "reconciled_at": now.isoformat(),
                }
                if new_status == "SUCCESS" and payout.status != PayoutStatus.SUCCESS.value:
                    payout.status = PayoutStatus.SUCCESS.value
                    metrics.incr(PAYOUT_SUCCESS)
                    await _notify_payout_success(db, payout)
                    updated += 1
                elif new_status == "FAILED" and payout.status != PayoutStatus.FAILED.value:
                    payout.status = PayoutStatus.FAILED.value
                    metrics.incr(PAYOUT_FAILED)
                    updated += 1
                elif new_status == "PROCESSING":
                    payout.status = PayoutStatus.PROCESSING.value
            elif payout.status == PayoutStatus.PENDING.value:
                # Never initiated — retry
                await _initiate_disbursement(db, payout)
                updated += 1

            created = payout.created_at
            if created is not None and created.tzinfo is None:
                created = created.replace(tzinfo=timezone.utc)
            if (
                payout.status in open_statuses
                and created is not None
                and created < cutoff
            ):
                payout.status = PayoutStatus.FAILED.value
                payout.raw_response = {
                    **(payout.raw_response or {}),
                    "reconcile_expired": True,
                    "expired_at": now.isoformat(),
                }
                metrics.incr(PAYOUT_FAILED)
                expired += 1
                updated += 1
        except Exception:
            logger.exception("Payout reconcile failed payout_id=%s", payout.id)
            errors += 1

    await db.flush()
    summary = {
        "checked": checked,
        "updated": updated,
        "expired": expired,
        "errors": errors,
    }
    logger.info("Payout reconcile %s", summary)
    return summary


async def list_business_payouts(
    db: AsyncSession, user: User, business_id: uuid.UUID
) -> list[MerchantPayout]:
    business = await db.get(Business, business_id)
    if not business:
        raise HTTPException(status_code=404, detail="Business not found")
    if business.owner_id != user.id and user.role != "ADMIN":
        raise HTTPException(status_code=403, detail="Forbidden")
    result = await db.execute(
        select(MerchantPayout)
        .where(MerchantPayout.business_id == business_id)
        .order_by(MerchantPayout.created_at.desc())
        .limit(100)
    )
    return list(result.scalars().all())


async def retry_payout(
    db: AsyncSession, admin: User, payout_id: uuid.UUID
) -> MerchantPayout:
    _ = admin
    payout = await db.get(MerchantPayout, payout_id)
    if not payout:
        raise HTTPException(status_code=404, detail="Payout not found")
    if payout.status == PayoutStatus.SUCCESS.value:
        return payout
    payout.status = PayoutStatus.PENDING.value
    await db.flush()
    return await _initiate_disbursement(db, payout)
