"""Rider delivery-fee disbursements (non-custodial)."""

from __future__ import annotations

import logging
import uuid
from decimal import Decimal

from fastapi import HTTPException
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.metrics import PAYOUT_FAILED, PAYOUT_INITIATED, PAYOUT_SUCCESS, metrics
from app.integrations.payments.disbursement import get_disbursement_provider
from app.models.audit import AuditLog
from app.models.notification import Notification
from app.models.payout import PayoutStatus, RiderPayout
from app.models.rider import Delivery, RiderProfile
from app.models.user import User

logger = logging.getLogger(__name__)


def _resolve_rider_payee(rider: RiderProfile, user: User | None) -> str | None:
    return rider.payout_phone or (user.phone if user else None)


def _resolve_rider_provider(rider: RiderProfile) -> str:
    if rider.payout_provider:
        return rider.payout_provider.upper()
    return "MOCK" if get_settings().payment_mock_auto_success else "MTN"


async def enqueue_rider_payout_for_delivery(
    db: AsyncSession, delivery: Delivery
) -> RiderPayout | None:
    """Create rider payout after DELIVERED. Idempotent on delivery_id."""
    if not delivery.rider_id:
        return None
    fee = Decimal(delivery.fee or 0)
    if fee <= 0:
        return None

    existing = await db.scalar(
        select(RiderPayout).where(RiderPayout.delivery_id == delivery.id)
    )
    if existing:
        return existing

    rider = await db.get(RiderProfile, delivery.rider_id)
    if not rider:
        return None
    user = await db.get(User, rider.user_id)
    payee = _resolve_rider_payee(rider, user)
    if not payee:
        db.add(
            AuditLog(
                actor_id=rider.user_id,
                action="RIDER_PAYOUT_SKIPPED_NO_PHONE",
                entity_type="delivery",
                entity_id=delivery.id,
                metadata_json={"rider_id": str(rider.id)},
            )
        )
        await db.flush()
        return None

    provider = _resolve_rider_provider(rider)
    payout = RiderPayout(
        delivery_id=delivery.id,
        order_id=delivery.order_id,
        rider_id=rider.id,
        amount=fee,
        currency=delivery.currency or "UGX",
        provider=provider,
        idempotency_key=f"rider-payout-{delivery.id}",
        payee_phone=payee,
        status=PayoutStatus.PENDING.value,
    )
    try:
        async with db.begin_nested():
            db.add(payout)
            await db.flush()
    except IntegrityError:
        return await db.scalar(
            select(RiderPayout).where(RiderPayout.delivery_id == delivery.id)
        )

    metrics.incr(PAYOUT_INITIATED)
    if not get_settings().payout_auto_execute:
        payout.raw_response = {"queued": True, "auto_execute": False}
        db.add(
            AuditLog(
                actor_id=rider.user_id,
                action="RIDER_PAYOUT_QUEUED",
                entity_type="rider_payout",
                entity_id=payout.id,
                metadata_json={"amount": str(payout.amount), "payee": payee},
            )
        )
        await db.flush()
        return payout
    return await _initiate(db, payout)


async def _initiate(db: AsyncSession, payout: RiderPayout) -> RiderPayout:
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
        await _notify_failed(db, payout, reason=str(exc))
        await db.flush()
        return payout
    except Exception as exc:
        logger.exception("Rider disbursement failed payout_id=%s", payout.id)
        payout.status = PayoutStatus.PENDING.value
        payout.raw_response = {"error": str(exc)}
        await db.flush()
        return payout

    payout.provider_reference = result.provider_reference
    payout.raw_response = result.raw
    if result.status == "SUCCESS":
        payout.status = PayoutStatus.SUCCESS.value
        metrics.incr(PAYOUT_SUCCESS)
        await _notify_success(db, payout)
    elif result.status == "FAILED":
        payout.status = PayoutStatus.FAILED.value
        metrics.incr(PAYOUT_FAILED)
        await _notify_failed(db, payout, reason="provider_failed")
    else:
        payout.status = PayoutStatus.PROCESSING.value
    await db.flush()
    return payout


async def _notify_success(db: AsyncSession, payout: RiderPayout) -> None:
    from app.services.ledger import post_rider_settled

    await post_rider_settled(db, payout, created_by="system")
    rider = await db.get(RiderProfile, payout.rider_id)
    if not rider:
        return
    db.add(
        Notification(
            user_id=rider.user_id,
            type="RIDER_PAYOUT_SUCCESS",
            title="Delivery fee sent",
            body=f"UGX {payout.amount} sent to {payout.payee_phone}",
            data={
                "payout_id": str(payout.id),
                "delivery_id": str(payout.delivery_id),
                "order_id": str(payout.order_id),
            },
        )
    )
    db.add(
        AuditLog(
            actor_id=rider.user_id,
            action="RIDER_PAYOUT_SUCCESS",
            entity_type="rider_payout",
            entity_id=payout.id,
            metadata_json={"amount": str(payout.amount), "payee": payout.payee_phone},
        )
    )


async def _notify_failed(
    db: AsyncSession, payout: RiderPayout, *, reason: str
) -> None:
    rider = await db.get(RiderProfile, payout.rider_id)
    if not rider:
        return
    db.add(
        Notification(
            user_id=rider.user_id,
            type="RIDER_PAYOUT_FAILED",
            title="Delivery fee payout failed",
            body=f"UGX {payout.amount} could not be sent — we will retry",
            data={
                "payout_id": str(payout.id),
                "reason": reason,
                "audience": "rider",
            },
        )
    )


async def execute_rider_payout(
    db: AsyncSession, admin: User, payout_id: uuid.UUID
) -> RiderPayout:
    payout = await db.get(RiderPayout, payout_id)
    if not payout:
        raise HTTPException(status_code=404, detail="Rider payout not found")
    if payout.status == PayoutStatus.SUCCESS.value:
        return payout
    payout.status = PayoutStatus.PENDING.value
    payout.raw_response = {
        **(payout.raw_response or {}),
        "admin_execute": True,
        "executed_by": str(admin.id),
    }
    await db.flush()
    result = await _initiate(db, payout)
    db.add(
        AuditLog(
            actor_id=admin.id,
            action="RIDER_PAYOUT_EXECUTED",
            entity_type="rider_payout",
            entity_id=payout.id,
            metadata_json={"status": result.status},
        )
    )
    await db.flush()
    return result


async def update_rider_payout_settings(
    db: AsyncSession,
    user: User,
    *,
    payout_phone: str,
    payout_provider: str = "MTN",
) -> RiderProfile:
    rider = await db.scalar(select(RiderProfile).where(RiderProfile.user_id == user.id))
    if not rider:
        raise HTTPException(status_code=404, detail="Not enrolled as a rider")
    rider.payout_phone = payout_phone
    rider.payout_provider = payout_provider.upper()
    await db.flush()
    return rider


async def list_my_rider_payouts(
    db: AsyncSession, user: User, *, limit: int = 50
) -> list[RiderPayout]:
    rider = await db.scalar(select(RiderProfile).where(RiderProfile.user_id == user.id))
    if not rider:
        raise HTTPException(status_code=404, detail="Not enrolled as a rider")
    return list(
        (
            await db.scalars(
                select(RiderPayout)
                .where(RiderPayout.rider_id == rider.id)
                .order_by(RiderPayout.created_at.desc())
                .limit(limit)
            )
        ).all()
    )


async def list_rider_payout_queue(
    db: AsyncSession, *, page: int = 1, page_size: int = 50
) -> tuple[list[RiderPayout], int]:
    open_s = {PayoutStatus.PENDING.value, PayoutStatus.PROCESSING.value}
    total = int(
        await db.scalar(
            select(func.count())
            .select_from(RiderPayout)
            .where(RiderPayout.status.in_(open_s))
        )
        or 0
    )
    rows = list(
        (
            await db.scalars(
                select(RiderPayout)
                .where(RiderPayout.status.in_(open_s))
                .order_by(RiderPayout.created_at.asc())
                .offset((page - 1) * page_size)
                .limit(page_size)
            )
        ).all()
    )
    return rows, total


async def apply_webhook_status(
    db: AsyncSession, payout: RiderPayout, status: str
) -> None:
    st = status.upper()
    if payout.status == PayoutStatus.SUCCESS.value:
        return
    if st == "SUCCESS":
        payout.status = PayoutStatus.SUCCESS.value
        metrics.incr(PAYOUT_SUCCESS)
        await _notify_success(db, payout)
    elif st == "FAILED":
        payout.status = PayoutStatus.FAILED.value
        metrics.incr(PAYOUT_FAILED)
        await _notify_failed(db, payout, reason="webhook_failed")
    else:
        payout.status = PayoutStatus.PROCESSING.value
