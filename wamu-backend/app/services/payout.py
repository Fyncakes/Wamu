"""Merchant payout service — enqueue after collection SUCCESS; process disbursement webhooks."""

from __future__ import annotations

import logging
import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal

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
    Split a gross amount into (net, platform_fee, bps).

    Prefer ``commission.compute_for_order`` for live payouts (fee on subtotal,
    delivery excluded). This helper remains for tests / legacy call sites.
    """
    from app.services.commission import bps_of, to_minor

    bps = get_settings().platform_fee_bps if fee_bps is None else int(fee_bps)
    if bps < 0:
        bps = 0
    gross_i = to_minor(gross)
    if bps == 0 or gross_i <= 0:
        return Decimal(gross_i), Decimal("0"), 0
    fee_i = bps_of(gross_i, bps)
    if fee_i >= gross_i:
        return Decimal(gross_i), Decimal("0"), 0
    return Decimal(gross_i - fee_i), Decimal(fee_i), bps


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
    was_success = payout.status == PayoutStatus.SUCCESS.value
    if was_success:
        payout.status = PayoutStatus.REVERSED.value
        payout.raw_response = {
            **(payout.raw_response or {}),
            "reversed_reason": reason,
        }
        from app.services.ledger import post_payout_reversal

        await post_payout_reversal(
            db, payout, created_by="system", reason=reason
        )
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
    # Commission on order subtotal (excl. delivery) — same engine as ledger.
    from app.services.commission import compute_for_order

    breakdown = compute_for_order(order)
    net = breakdown.as_decimal_net()
    fee = breakdown.as_decimal_fee()
    bps = breakdown.commission_bps
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

    # Phase B: queue entitlement without calling disbursement when auto-execute is off.
    if not get_settings().payout_auto_execute:
        payout.raw_response = {
            **(payout.raw_response or {}),
            "queued": True,
            "auto_execute": False,
        }
        db.add(
            AuditLog(
                actor_id=business.owner_id,
                action="PAYOUT_QUEUED",
                entity_type="merchant_payout",
                entity_id=payout.id,
                metadata_json={
                    "amount": str(payout.amount),
                    "platform_fee": str(payout.platform_fee),
                    "fee_bps": payout.fee_bps,
                    "provider": provider_name,
                    "payee": payee,
                },
            )
        )
        await db.flush()
        return payout

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
        await _notify_payout_failed(db, payout, reason=str(exc))
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
        await _notify_payout_failed(db, payout, reason="provider_failed")
    else:
        payout.status = PayoutStatus.PROCESSING.value
    await db.flush()
    return payout


async def _notify_payout_success(db: AsyncSession, payout: MerchantPayout) -> None:
    from app.services.ledger import post_payout_settled

    await post_payout_settled(db, payout, created_by="system")
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


async def _notify_payout_failed(
    db: AsyncSession, payout: MerchantPayout, *, reason: str = "failed"
) -> None:
    """Stub merchant + audit notification for failed disbursements (Phase B)."""
    business = await db.get(Business, payout.business_id)
    if not business:
        return
    db.add(
        Notification(
            user_id=business.owner_id,
            type="PAYOUT_FAILED",
            title="Payout failed",
            body=f"UGX {payout.amount} to {payout.payee_phone} could not be sent",
            data={
                "payout_id": str(payout.id),
                "payment_id": str(payout.payment_id),
                "order_id": str(payout.order_id),
                "reason": reason,
                "audience": "merchant",
            },
        )
    )
    db.add(
        AuditLog(
            actor_id=business.owner_id,
            action="PAYOUT_FAILED",
            entity_type="merchant_payout",
            entity_id=payout.id,
            metadata_json={
                "amount": str(payout.amount),
                "provider": payout.provider,
                "payee": payout.payee_phone,
                "reason": reason,
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

    prov = provider.upper()
    ref = payload.provider_reference

    # Merchant → rider → owner (same callback URL for all disbursements)
    payout = await db.scalar(
        select(MerchantPayout).where(
            MerchantPayout.provider == prov,
            MerchantPayout.provider_reference == ref,
        )
    )
    if payout:
        if payload.amount is not None and Decimal(payload.amount) != payout.amount:
            event.notes = "Amount mismatch"
            event.processed_at = datetime.now(timezone.utc)
            await db.flush()
            raise HTTPException(status_code=400, detail="Amount mismatch")
        if payout.status == PayoutStatus.SUCCESS.value:
            event.processed_at = datetime.now(timezone.utc)
            await db.flush()
            return {"status": "already_success", "kind": "merchant"}
        if payload.status.upper() == "SUCCESS":
            payout.status = PayoutStatus.SUCCESS.value
            metrics.incr(PAYOUT_SUCCESS)
            await _notify_payout_success(db, payout)
        elif payload.status.upper() == "FAILED":
            payout.status = PayoutStatus.FAILED.value
            metrics.incr(PAYOUT_FAILED)
            await _notify_payout_failed(db, payout, reason="webhook_failed")
        else:
            payout.status = PayoutStatus.PROCESSING.value
        event.processed_at = datetime.now(timezone.utc)
        await db.flush()
        return {"status": "processed", "kind": "merchant", "payout_status": payout.status}

    from app.models.payout import OwnerPayout, RiderPayout
    from app.services import owner_payout as owner_svc
    from app.services import rider_payout as rider_svc

    rider = await db.scalar(
        select(RiderPayout).where(
            RiderPayout.provider == prov,
            RiderPayout.provider_reference == ref,
        )
    )
    if rider:
        await rider_svc.apply_webhook_status(db, rider, payload.status)
        event.processed_at = datetime.now(timezone.utc)
        await db.flush()
        return {"status": "processed", "kind": "rider", "payout_status": rider.status}

    owner = await db.scalar(
        select(OwnerPayout).where(
            OwnerPayout.provider == prov,
            OwnerPayout.provider_reference == ref,
        )
    )
    if owner:
        await owner_svc.apply_webhook_status(db, owner, payload.status)
        event.processed_at = datetime.now(timezone.utc)
        await db.flush()
        return {"status": "processed", "kind": "owner", "payout_status": owner.status}

    event.notes = "Payout not found"
    event.processed_at = datetime.now(timezone.utc)
    await db.flush()
    return {"status": "ignored", "reason": "payout_not_found"}


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
                    await _notify_payout_failed(db, payout, reason="reconcile_failed")
                    updated += 1
                elif new_status == "PROCESSING":
                    payout.status = PayoutStatus.PROCESSING.value
            elif (
                payout.status == PayoutStatus.PENDING.value
                and get_settings().payout_auto_execute
            ):
                # Never initiated — retry only when auto-execute is on
                await _initiate_disbursement(db, payout)
                updated += 1

            created = payout.created_at
            if created is not None and created.tzinfo is None:
                created = created.replace(tzinfo=timezone.utc)
            if (
                payout.status in open_statuses
                and created is not None
                and created < cutoff
                and get_settings().payout_auto_execute
            ):
                # Queued entitlements (auto-execute off) must not expire into FAILED
                payout.status = PayoutStatus.FAILED.value
                payout.raw_response = {
                    **(payout.raw_response or {}),
                    "reconcile_expired": True,
                    "expired_at": now.isoformat(),
                }
                metrics.incr(PAYOUT_FAILED)
                await _notify_payout_failed(db, payout, reason="reconcile_expired")
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


async def execute_payout(
    db: AsyncSession, admin: User, payout_id: uuid.UUID
) -> MerchantPayout:
    """
    Phase C — admin forces disbursement for a queued/failed payout.
    Works even when PAYOUT_AUTO_EXECUTE=false.
    """
    payout = await db.get(MerchantPayout, payout_id)
    if not payout:
        raise HTTPException(status_code=404, detail="Payout not found")
    if payout.status == PayoutStatus.SUCCESS.value:
        return payout
    if payout.status == PayoutStatus.REVERSED.value:
        raise HTTPException(status_code=400, detail="Cannot execute a reversed payout")

    before = payout.status
    payout.status = PayoutStatus.PENDING.value
    payout.raw_response = {
        **(payout.raw_response or {}),
        "admin_execute": True,
        "executed_by": str(admin.id),
    }
    await db.flush()
    payout = await _initiate_disbursement(db, payout)
    db.add(
        AuditLog(
            actor_id=admin.id,
            action="PAYOUT_EXECUTED",
            entity_type="merchant_payout",
            entity_id=payout.id,
            metadata_json={
                "before_status": before,
                "after_status": payout.status,
                "provider": payout.provider,
                "amount": str(payout.amount),
            },
        )
    )
    await db.flush()
    return payout


async def execute_payout_queue(
    db: AsyncSession,
    admin: User,
    *,
    limit: int = 50,
    payout_ids: list[uuid.UUID] | None = None,
) -> dict:
    """Batch-execute PENDING queue items (Phase C ops control)."""
    open_statuses = {PayoutStatus.PENDING.value, PayoutStatus.FAILED.value}
    if payout_ids:
        q = select(MerchantPayout).where(MerchantPayout.id.in_(payout_ids))
    else:
        q = (
            select(MerchantPayout)
            .where(MerchantPayout.status.in_(open_statuses))
            .order_by(MerchantPayout.created_at.asc())
            .limit(limit)
        )
    rows = list((await db.scalars(q)).all())
    executed = success = failed = skipped = 0
    for payout in rows:
        if payout.status == PayoutStatus.SUCCESS.value:
            skipped += 1
            continue
        if payout.status == PayoutStatus.REVERSED.value:
            skipped += 1
            continue
        executed += 1
        result = await execute_payout(db, admin, payout.id)
        if result.status == PayoutStatus.SUCCESS.value:
            success += 1
        elif result.status == PayoutStatus.FAILED.value:
            failed += 1
    summary = {
        "selected": len(rows),
        "executed": executed,
        "success": success,
        "failed": failed,
        "skipped": skipped,
        "processing": executed - success - failed,
    }
    db.add(
        AuditLog(
            actor_id=admin.id,
            action="PAYOUT_QUEUE_EXECUTED",
            entity_type="merchant_payout",
            entity_id=None,
            metadata_json=summary,
        )
    )
    await db.flush()
    return summary
