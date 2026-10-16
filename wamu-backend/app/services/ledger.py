"""Double-entry ledger service — post balanced groups; derive balances."""

from __future__ import annotations

import logging
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from uuid import UUID

from fastapi import HTTPException
from sqlalchemy import Select, case, func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.ledger import (
    LedgerAccountType,
    LedgerDirection,
    LedgerEntry,
    LedgerSourceType,
)
from app.models.order import Order, OrderStatus
from app.models.payment import Payment
from app.models.rider import Delivery
from app.services.commission import CommissionBreakdown, compute_for_order, proportional_refund

logger = logging.getLogger(__name__)


@dataclass(frozen=True, slots=True)
class LedgerLeg:
    account_type: str
    direction: str
    amount_minor: int
    account_id: UUID | None = None
    leg_key: str = ""  # suffix for idempotency uniqueness within a group


async def post_group(
    db: AsyncSession,
    *,
    legs: list[LedgerLeg],
    source_type: str,
    source_id: UUID,
    idempotency_prefix: str,
    created_by: str = "system",
    notes: str | None = None,
    currency: str = "UGX",
) -> uuid.UUID | None:
    """
    Insert a balanced debit/credit group.
    Returns entry_group_id, or None if the prefix already exists (idempotent skip).
    """
    if not legs:
        raise HTTPException(status_code=500, detail="Ledger group has no legs")

    debit = sum(l.amount_minor for l in legs if l.direction == LedgerDirection.DEBIT.value)
    credit = sum(l.amount_minor for l in legs if l.direction == LedgerDirection.CREDIT.value)
    if debit != credit:
        raise HTTPException(
            status_code=500,
            detail=f"Unbalanced ledger group: debit={debit} credit={credit}",
        )
    if debit == 0:
        # Nothing to post (e.g. zero-amount edge) — still record nothing
        return None

    # Idempotency: stable prefix — if any prior leg exists, skip.
    existing = await db.scalar(
        select(LedgerEntry.entry_group_id)
        .where(LedgerEntry.idempotency_key.like(f"{idempotency_prefix}:%"))
        .limit(1)
    )
    if existing:
        return existing

    nonzero = [l for l in legs if l.amount_minor > 0]
    if not nonzero:
        return None

    group_id = uuid.uuid4()
    for i, leg in enumerate(nonzero):
        key = f"{idempotency_prefix}:{leg.leg_key or leg.account_type}:{i}"
        db.add(
            LedgerEntry(
                entry_group_id=group_id,
                account_type=leg.account_type,
                account_id=leg.account_id,
                direction=leg.direction,
                amount_minor=leg.amount_minor,
                currency=currency,
                source_type=source_type,
                source_id=source_id,
                idempotency_key=key,
                created_by=created_by,
                notes=notes,
            )
        )
    try:
        async with db.begin_nested():
            await db.flush()
    except IntegrityError:
        again = await db.scalar(
            select(LedgerEntry.entry_group_id)
            .where(LedgerEntry.idempotency_key.like(f"{idempotency_prefix}:%"))
            .limit(1)
        )
        return again
    return group_id


def _legs_for_breakdown(
    bd: CommissionBreakdown,
    *,
    rider_id: UUID | None,
) -> list[LedgerLeg]:
    legs: list[LedgerLeg] = [
        LedgerLeg(
            account_type=LedgerAccountType.PROVIDER_CLEARING.value,
            direction=LedgerDirection.DEBIT.value,
            amount_minor=bd.customer_total_minor,
            leg_key="clearing_in",
        ),
        LedgerLeg(
            account_type=LedgerAccountType.MERCHANT_PAYABLE.value,
            direction=LedgerDirection.CREDIT.value,
            amount_minor=bd.merchant_net_minor,
            account_id=bd.business_id,
            leg_key="merchant",
        ),
        LedgerLeg(
            account_type=LedgerAccountType.WAMU_COMMISSION.value,
            direction=LedgerDirection.CREDIT.value,
            amount_minor=bd.commission_minor,
            leg_key="commission",
        ),
    ]
    if bd.rider_payable_minor > 0:
        legs.append(
            LedgerLeg(
                account_type=LedgerAccountType.RIDER_PAYABLE.value,
                direction=LedgerDirection.CREDIT.value,
                amount_minor=bd.rider_payable_minor,
                account_id=rider_id,
                leg_key="rider",
            )
        )
    if bd.provider_fee_minor > 0:
        legs.extend(
            [
                LedgerLeg(
                    account_type=LedgerAccountType.WAMU_PROVIDER_FEES.value,
                    direction=LedgerDirection.DEBIT.value,
                    amount_minor=bd.provider_fee_minor,
                    leg_key="provider_fee",
                ),
                LedgerLeg(
                    account_type=LedgerAccountType.PROVIDER_CLEARING.value,
                    direction=LedgerDirection.CREDIT.value,
                    amount_minor=bd.provider_fee_minor,
                    leg_key="clearing_fee",
                ),
            ]
        )
    # Drop zero legs (commission 0 still ok — merchant gets full gross)
    return [l for l in legs if l.amount_minor > 0]


async def _rider_id_for_order(db: AsyncSession, order_id: UUID) -> UUID | None:
    delivery = await db.scalar(select(Delivery).where(Delivery.order_id == order_id))
    if delivery and delivery.rider_id:
        return delivery.rider_id
    return None


async def post_payment_confirmed(
    db: AsyncSession,
    payment: Payment,
    order: Order,
    *,
    created_by: str = "system",
) -> uuid.UUID | None:
    """Post ledger for a SUCCESS collection. Idempotent per order."""
    bd = compute_for_order(order)
    rider_id = await _rider_id_for_order(db, order.id)
    legs = _legs_for_breakdown(bd, rider_id=rider_id)
    return await post_group(
        db,
        legs=legs,
        source_type=LedgerSourceType.ORDER.value,
        source_id=order.id,
        idempotency_prefix=f"order:{order.id}:payment_confirmed",
        created_by=created_by,
        notes=f"payment={payment.id}",
        currency=bd.currency,
    )


async def post_payout_settled(
    db: AsyncSession,
    payout: "MerchantPayout",
    *,
    created_by: str = "system",
) -> uuid.UUID | None:
    """Clear merchant payable when disbursement SUCCESS (money left via MoMo)."""
    from app.services.commission import to_minor

    amount_minor = to_minor(payout.amount)
    if amount_minor <= 0:
        return None
    return await post_group(
        db,
        legs=[
            LedgerLeg(
                account_type=LedgerAccountType.MERCHANT_PAYABLE.value,
                direction=LedgerDirection.DEBIT.value,
                amount_minor=amount_minor,
                account_id=payout.business_id,
                leg_key="merchant_settle",
            ),
            LedgerLeg(
                account_type=LedgerAccountType.PROVIDER_CLEARING.value,
                direction=LedgerDirection.CREDIT.value,
                amount_minor=amount_minor,
                leg_key="clearing_out",
            ),
        ],
        source_type=LedgerSourceType.PAYOUT.value,
        source_id=payout.id,
        idempotency_prefix=f"payout:{payout.id}:settled",
        created_by=created_by,
        notes=f"disbursement to {payout.payee_phone}",
        currency=payout.currency or "UGX",
    )


async def post_payout_reversal(
    db: AsyncSession,
    payout: "MerchantPayout",
    *,
    created_by: str = "system",
    reason: str = "reversed",
) -> uuid.UUID | None:
    """Re-open merchant payable after a SUCCESS payout is reversed."""
    from app.services.commission import to_minor

    amount_minor = to_minor(payout.amount)
    if amount_minor <= 0:
        return None
    return await post_group(
        db,
        legs=[
            LedgerLeg(
                account_type=LedgerAccountType.PROVIDER_CLEARING.value,
                direction=LedgerDirection.DEBIT.value,
                amount_minor=amount_minor,
                leg_key="clearing_rev",
            ),
            LedgerLeg(
                account_type=LedgerAccountType.MERCHANT_PAYABLE.value,
                direction=LedgerDirection.CREDIT.value,
                amount_minor=amount_minor,
                account_id=payout.business_id,
                leg_key="merchant_rev",
            ),
        ],
        source_type=LedgerSourceType.PAYOUT.value,
        source_id=payout.id,
        idempotency_prefix=f"payout:{payout.id}:reversed:{reason}",
        created_by=created_by,
        notes=reason,
        currency=payout.currency or "UGX",
    )


async def post_rider_settled(
    db: AsyncSession,
    payout: "RiderPayout",
    *,
    created_by: str = "system",
) -> uuid.UUID | None:
    """Clear rider payable when delivery-fee disbursement SUCCESS."""
    from app.services.commission import to_minor

    amount_minor = to_minor(payout.amount)
    if amount_minor <= 0:
        return None
    return await post_group(
        db,
        legs=[
            LedgerLeg(
                account_type=LedgerAccountType.RIDER_PAYABLE.value,
                direction=LedgerDirection.DEBIT.value,
                amount_minor=amount_minor,
                account_id=payout.rider_id,
                leg_key="rider_settle",
            ),
            LedgerLeg(
                account_type=LedgerAccountType.PROVIDER_CLEARING.value,
                direction=LedgerDirection.CREDIT.value,
                amount_minor=amount_minor,
                leg_key="clearing_out",
            ),
        ],
        source_type=LedgerSourceType.PAYOUT.value,
        source_id=payout.id,
        idempotency_prefix=f"rider_payout:{payout.id}:settled",
        created_by=created_by,
        notes=f"rider fee to {payout.payee_phone}",
        currency=payout.currency or "UGX",
    )


async def post_owner_commission_withdrawn(
    db: AsyncSession,
    payout: "OwnerPayout",
    *,
    created_by: str = "system",
) -> uuid.UUID | None:
    """Move commission out of platform earnings into owner MoMo (via clearing)."""
    amount_minor = int(payout.amount_minor)
    if amount_minor <= 0:
        return None
    return await post_group(
        db,
        legs=[
            LedgerLeg(
                account_type=LedgerAccountType.WAMU_COMMISSION.value,
                direction=LedgerDirection.DEBIT.value,
                amount_minor=amount_minor,
                leg_key="commission_out",
            ),
            LedgerLeg(
                account_type=LedgerAccountType.WAMU_OWNER_PAYOUT.value,
                direction=LedgerDirection.CREDIT.value,
                amount_minor=amount_minor,
                leg_key="owner_in",
            ),
            LedgerLeg(
                account_type=LedgerAccountType.WAMU_OWNER_PAYOUT.value,
                direction=LedgerDirection.DEBIT.value,
                amount_minor=amount_minor,
                leg_key="owner_out",
            ),
            LedgerLeg(
                account_type=LedgerAccountType.PROVIDER_CLEARING.value,
                direction=LedgerDirection.CREDIT.value,
                amount_minor=amount_minor,
                leg_key="clearing_out",
            ),
        ],
        source_type=LedgerSourceType.PAYOUT.value,
        source_id=payout.id,
        idempotency_prefix=f"owner_payout:{payout.id}:withdrawn",
        created_by=created_by,
        notes=f"owner withdraw to {payout.payee_phone}",
        currency=payout.currency or "UGX",
    )


async def post_refund_reversal(
    db: AsyncSession,
    payment: Payment,
    order: Order,
    *,
    refund_subtotal_minor: int | None = None,
    reason: str = "refund",
    created_by: str = "system",
) -> uuid.UUID | None:
    """
    Reverse (full or partial) the payment_confirmed group.
    Rider fee retained when order already DELIVERED / OUT_FOR_DELIVERY.
    """
    original = compute_for_order(order)
    retain_rider = order.status in {
        OrderStatus.DELIVERED.value,
        OrderStatus.OUT_FOR_DELIVERY.value,
    }
    refund_gross = (
        original.gross_minor
        if refund_subtotal_minor is None
        else int(refund_subtotal_minor)
    )
    bd = proportional_refund(
        original, refund_subtotal_minor=refund_gross, retain_rider=retain_rider
    )
    rider_id = await _rider_id_for_order(db, order.id)
    # Reverse = swap debit/credit
    forward = _legs_for_breakdown(bd, rider_id=rider_id)
    reverse_legs = [
        LedgerLeg(
            account_type=l.account_type,
            direction=(
                LedgerDirection.CREDIT.value
                if l.direction == LedgerDirection.DEBIT.value
                else LedgerDirection.DEBIT.value
            ),
            amount_minor=l.amount_minor,
            account_id=l.account_id,
            leg_key=f"rev_{l.leg_key}",
        )
        for l in forward
    ]
    refund_id = uuid.uuid4()
    return await post_group(
        db,
        legs=reverse_legs,
        source_type=LedgerSourceType.REFUND.value,
        source_id=refund_id,
        idempotency_prefix=f"order:{order.id}:refund:{reason}:{refund_gross}",
        created_by=created_by,
        notes=f"payment={payment.id}; reason={reason}",
        currency=bd.currency,
    )


async def account_balance_minor(
    db: AsyncSession,
    account_type: str,
    account_id: UUID | None = None,
    *,
    all_accounts: bool = False,
) -> int:
    """Credit − debit (positive = amount owed / earned depending on account).

    - ``account_id`` set: that specific sub-account
    - ``all_accounts=True``: every row of this account_type
    - else: rows where account_id IS NULL (platform-level accounts)
    """
    q: Select = select(
        func.coalesce(
            func.sum(
                case(
                    (
                        LedgerEntry.direction == LedgerDirection.CREDIT.value,
                        LedgerEntry.amount_minor,
                    ),
                    else_=-LedgerEntry.amount_minor,
                )
            ),
            0,
        )
    ).where(LedgerEntry.account_type == account_type)
    if account_id is not None:
        q = q.where(LedgerEntry.account_id == account_id)
    elif not all_accounts:
        q = q.where(LedgerEntry.account_id.is_(None))
    value = await db.scalar(q)
    return int(value or 0)


async def sum_account_credits(
    db: AsyncSession,
    account_type: str,
    *,
    account_id: UUID | None = None,
    since: datetime | None = None,
    until: datetime | None = None,
) -> int:
    q = select(func.coalesce(func.sum(LedgerEntry.amount_minor), 0)).where(
        LedgerEntry.account_type == account_type,
        LedgerEntry.direction == LedgerDirection.CREDIT.value,
    )
    if account_id is not None:
        q = q.where(LedgerEntry.account_id == account_id)
    if since is not None:
        q = q.where(LedgerEntry.created_at >= since)
    if until is not None:
        q = q.where(LedgerEntry.created_at <= until)
    return int(await db.scalar(q) or 0)


async def sum_account_debits(
    db: AsyncSession,
    account_type: str,
    *,
    account_id: UUID | None = None,
    since: datetime | None = None,
    until: datetime | None = None,
) -> int:
    q = select(func.coalesce(func.sum(LedgerEntry.amount_minor), 0)).where(
        LedgerEntry.account_type == account_type,
        LedgerEntry.direction == LedgerDirection.DEBIT.value,
    )
    if account_id is not None:
        q = q.where(LedgerEntry.account_id == account_id)
    if since is not None:
        q = q.where(LedgerEntry.created_at >= since)
    if until is not None:
        q = q.where(LedgerEntry.created_at <= until)
    return int(await db.scalar(q) or 0)


async def list_entries(
    db: AsyncSession,
    *,
    account_type: str | None = None,
    account_id: UUID | None = None,
    source_type: str | None = None,
    since: datetime | None = None,
    until: datetime | None = None,
    page: int = 1,
    page_size: int = 50,
) -> tuple[list[LedgerEntry], int]:
    filters = []
    if account_type:
        filters.append(LedgerEntry.account_type == account_type)
    if account_id is not None:
        filters.append(LedgerEntry.account_id == account_id)
    if source_type:
        filters.append(LedgerEntry.source_type == source_type)
    if since is not None:
        filters.append(LedgerEntry.created_at >= since)
    if until is not None:
        filters.append(LedgerEntry.created_at <= until)

    count_q = select(func.count()).select_from(LedgerEntry)
    list_q = select(LedgerEntry).order_by(LedgerEntry.created_at.desc())
    for f in filters:
        count_q = count_q.where(f)
        list_q = list_q.where(f)
    total = int(await db.scalar(count_q) or 0)
    rows = (
        await db.scalars(list_q.offset((page - 1) * page_size).limit(page_size))
    ).all()
    return list(rows), total
