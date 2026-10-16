"""Platform commission withdrawal to owner MoMo (admin-initiated)."""

from __future__ import annotations

import logging
import uuid
from decimal import Decimal

from fastapi import HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.metrics import PAYOUT_FAILED, PAYOUT_INITIATED, PAYOUT_SUCCESS, metrics
from app.integrations.payments.disbursement import get_disbursement_provider
from app.models.audit import AuditLog
from app.models.ledger import LedgerAccountType
from app.models.payout import OwnerPayout, PayoutStatus
from app.models.user import User
from app.services.commission import to_minor
from app.services.ledger import account_balance_minor

logger = logging.getLogger(__name__)


async def available_commission_minor(db: AsyncSession) -> int:
    """Credit − debit balance on wamu_commission (platform-level)."""
    return await account_balance_minor(
        db, LedgerAccountType.WAMU_COMMISSION.value, all_accounts=True
    )


async def request_owner_payout(
    db: AsyncSession,
    admin: User,
    *,
    amount_minor: int | None = None,
    notes: str | None = None,
    idempotency_key: str | None = None,
) -> OwnerPayout:
    """
    Queue (or auto-execute) a commission withdrawal.
    amount_minor=None → withdraw full available balance.
    """
    settings = get_settings()
    payee = (settings.owner_payout_phone or "").strip()
    if not payee:
        raise HTTPException(
            status_code=400,
            detail="OWNER_PAYOUT_PHONE is not configured",
        )
    available = await available_commission_minor(db)
    withdraw = available if amount_minor is None else int(amount_minor)
    if withdraw <= 0:
        raise HTTPException(status_code=400, detail="Nothing to withdraw")
    if withdraw > available:
        raise HTTPException(
            status_code=400,
            detail=f"Amount exceeds available commission ({available} minor)",
        )

    key = idempotency_key or f"owner-{admin.id}-{withdraw}-{uuid.uuid4().hex[:8]}"
    existing = await db.scalar(
        select(OwnerPayout).where(OwnerPayout.idempotency_key == key)
    )
    if existing:
        return existing

    provider = (settings.owner_payout_provider or "MTN").upper()
    payout = OwnerPayout(
        amount=Decimal(withdraw),
        amount_minor=withdraw,
        currency="UGX",
        provider=provider,
        idempotency_key=key,
        payee_phone=payee,
        status=PayoutStatus.PENDING.value,
        requested_by=admin.id,
        notes=notes,
    )
    db.add(payout)
    await db.flush()
    metrics.incr(PAYOUT_INITIATED)

    db.add(
        AuditLog(
            actor_id=admin.id,
            action="OWNER_PAYOUT_REQUESTED",
            entity_type="owner_payout",
            entity_id=payout.id,
            metadata_json={
                "amount_minor": withdraw,
                "available_before": available,
                "payee": payee,
            },
        )
    )
    await db.flush()

    if not settings.payout_auto_execute:
        payout.raw_response = {"queued": True, "auto_execute": False}
        await db.flush()
        return payout
    return await _initiate(db, payout)


async def _initiate(db: AsyncSession, payout: OwnerPayout) -> OwnerPayout:
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
        logger.exception("Owner disbursement failed payout_id=%s", payout.id)
        payout.status = PayoutStatus.PENDING.value
        payout.raw_response = {"error": str(exc)}
        await db.flush()
        return payout

    payout.provider_reference = result.provider_reference
    payout.raw_response = result.raw
    if result.status == "SUCCESS":
        payout.status = PayoutStatus.SUCCESS.value
        metrics.incr(PAYOUT_SUCCESS)
        await _on_success(db, payout)
    elif result.status == "FAILED":
        payout.status = PayoutStatus.FAILED.value
        metrics.incr(PAYOUT_FAILED)
    else:
        payout.status = PayoutStatus.PROCESSING.value
    await db.flush()
    return payout


async def _on_success(db: AsyncSession, payout: OwnerPayout) -> None:
    from app.services.ledger import post_owner_commission_withdrawn

    await post_owner_commission_withdrawn(db, payout, created_by="system")
    db.add(
        AuditLog(
            actor_id=payout.requested_by,
            action="OWNER_PAYOUT_SUCCESS",
            entity_type="owner_payout",
            entity_id=payout.id,
            metadata_json={
                "amount_minor": payout.amount_minor,
                "payee": payout.payee_phone,
            },
        )
    )


async def execute_owner_payout(
    db: AsyncSession, admin: User, payout_id: uuid.UUID
) -> OwnerPayout:
    payout = await db.get(OwnerPayout, payout_id)
    if not payout:
        raise HTTPException(status_code=404, detail="Owner payout not found")
    if payout.status == PayoutStatus.SUCCESS.value:
        return payout
    payout.status = PayoutStatus.PENDING.value
    payout.raw_response = {
        **(payout.raw_response or {}),
        "admin_execute": True,
        "executed_by": str(admin.id),
    }
    await db.flush()
    return await _initiate(db, payout)


async def list_owner_payouts(
    db: AsyncSession, *, page: int = 1, page_size: int = 50
) -> tuple[list[OwnerPayout], int]:
    total = int(await db.scalar(select(func.count()).select_from(OwnerPayout)) or 0)
    rows = list(
        (
            await db.scalars(
                select(OwnerPayout)
                .order_by(OwnerPayout.created_at.desc())
                .offset((page - 1) * page_size)
                .limit(page_size)
            )
        ).all()
    )
    return rows, total


async def apply_webhook_status(
    db: AsyncSession, payout: OwnerPayout, status: str
) -> None:
    st = status.upper()
    if payout.status == PayoutStatus.SUCCESS.value:
        return
    if st == "SUCCESS":
        payout.status = PayoutStatus.SUCCESS.value
        metrics.incr(PAYOUT_SUCCESS)
        await _on_success(db, payout)
    elif st == "FAILED":
        payout.status = PayoutStatus.FAILED.value
        metrics.incr(PAYOUT_FAILED)
    else:
        payout.status = PayoutStatus.PROCESSING.value
