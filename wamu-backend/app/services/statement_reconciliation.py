"""Phase B — ingest provider statement lines, match to payments/payouts, post suspense."""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from typing import Any
from uuid import UUID

from fastapi import HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.models.audit import AuditLog
from app.models.ledger import LedgerAccountType, LedgerDirection
from app.models.payment import Payment, PaymentStatus
from app.models.payout import MerchantPayout, PayoutStatus
from app.models.reconciliation import (
    ProviderStatementBatch,
    ProviderStatementLine,
    ReconciliationRun,
    ReconciliationRunStatus,
    StatementMatchStatus,
    SuspenseItem,
    SuspenseStatus,
)
from app.models.user import User
from app.services.commission import to_minor
from app.services.ledger import LedgerLeg, account_balance_minor, post_group

logger = logging.getLogger(__name__)


async def _post_suspense_ledger(
    db: AsyncSession,
    *,
    line: ProviderStatementLine,
    created_by: str,
) -> UUID | None:
    """Park unmatched amount in suspense (balanced against provider_clearing)."""
    if line.amount_minor <= 0:
        return None
    return await post_group(
        db,
        legs=[
            LedgerLeg(
                account_type=LedgerAccountType.PROVIDER_CLEARING.value,
                direction=LedgerDirection.DEBIT.value,
                amount_minor=line.amount_minor,
                leg_key="clearing",
            ),
            LedgerLeg(
                account_type=LedgerAccountType.SUSPENSE.value,
                direction=LedgerDirection.CREDIT.value,
                amount_minor=line.amount_minor,
                leg_key="suspense",
            ),
        ],
        source_type="adjustment",
        source_id=line.id,
        idempotency_prefix=f"suspense:line:{line.id}",
        created_by=created_by,
        notes=f"unmatched statement {line.external_ref}",
        currency=line.currency,
    )


async def import_statement_lines(
    db: AsyncSession,
    *,
    provider: str,
    lines: list[dict[str, Any]],
    source: str = "import",
    created_by: str = "system",
    notes: str | None = None,
) -> ProviderStatementBatch:
    """Persist a batch of statement lines (admin import or synthetic pull)."""
    provider = provider.upper()
    batch = ProviderStatementBatch(
        provider=provider,
        source=source,
        notes=notes,
        created_by=created_by,
        status=ReconciliationRunStatus.COMPLETED.value,
    )
    db.add(batch)
    await db.flush()

    for raw in lines:
        ref = str(raw.get("external_ref") or raw.get("reference") or "").strip()
        if not ref:
            continue
        amount = raw.get("amount_minor")
        if amount is None and raw.get("amount") is not None:
            amount = to_minor(Decimal(str(raw["amount"])))
        amount_i = int(amount or 0)
        occurred = raw.get("occurred_at")
        if isinstance(occurred, str):
            try:
                occurred = datetime.fromisoformat(occurred.replace("Z", "+00:00"))
            except ValueError:
                occurred = None
        db.add(
            ProviderStatementLine(
                batch_id=batch.id,
                provider=provider,
                external_ref=ref,
                amount_minor=amount_i,
                currency=str(raw.get("currency") or "UGX"),
                occurred_at=occurred,
                raw=raw,
                match_status=StatementMatchStatus.UNMATCHED.value,
            )
        )
    await db.flush()
    return batch


async def build_synthetic_statement(
    db: AsyncSession,
    *,
    provider: str = "MTN",
    hours: int = 48,
    include_orphan: bool = False,
    created_by: str = "system",
) -> ProviderStatementBatch:
    """
    Phase B without live provider APIs: build statement lines from our SUCCESS
    payments (and optional orphan line to exercise suspense).
    """
    provider = provider.upper()
    since = datetime.now(timezone.utc) - timedelta(hours=hours)
    q = select(Payment).where(
        Payment.status == PaymentStatus.SUCCESS.value,
        Payment.created_at >= since,
    )
    if provider != "ALL":
        q = q.where(Payment.provider == provider)
    payments = list((await db.scalars(q.limit(500))).all())

    lines: list[dict[str, Any]] = []
    for p in payments:
        ref = p.provider_reference or str(p.id)
        lines.append(
            {
                "external_ref": ref,
                "amount_minor": to_minor(p.amount),
                "currency": p.currency or "UGX",
                "occurred_at": p.created_at.isoformat() if p.created_at else None,
                "kind": "collection",
                "payment_id": str(p.id),
            }
        )
    if include_orphan:
        lines.append(
            {
                "external_ref": f"ORPHAN-{datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S')}",
                "amount_minor": 5000,
                "currency": "UGX",
                "kind": "orphan",
            }
        )
    return await import_statement_lines(
        db,
        provider=provider if provider != "ALL" else "MTN",
        lines=lines,
        source="synthetic",
        created_by=created_by,
        notes=f"synthetic pull hours={hours} payments={len(payments)}",
    )


async def match_batch(
    db: AsyncSession,
    batch: ProviderStatementBatch,
    *,
    created_by: str = "system",
) -> ReconciliationRun:
    """Match statement lines to payments (by provider_reference) or payouts."""
    run = ReconciliationRun(
        provider=batch.provider,
        batch_id=batch.id,
        status=ReconciliationRunStatus.RUNNING.value,
        created_by=created_by,
    )
    db.add(run)
    await db.flush()

    lines = list(
        (
            await db.scalars(
                select(ProviderStatementLine).where(
                    ProviderStatementLine.batch_id == batch.id
                )
            )
        ).all()
    )
    matched = unmatched = suspense_n = 0

    for line in lines:
        if line.match_status in {
            StatementMatchStatus.MATCHED.value,
            StatementMatchStatus.IGNORED.value,
        }:
            if line.match_status == StatementMatchStatus.MATCHED.value:
                matched += 1
            continue

        payment = await db.scalar(
            select(Payment).where(
                Payment.provider_reference == line.external_ref,
            )
        )
        if payment is None:
            # Also try payout provider_reference
            payout = await db.scalar(
                select(MerchantPayout).where(
                    MerchantPayout.provider_reference == line.external_ref
                )
            )
            if payout is not None:
                pay_amt = to_minor(payout.amount)
                if abs(pay_amt - line.amount_minor) <= 1:
                    line.match_status = StatementMatchStatus.MATCHED.value
                    line.matched_payout_id = payout.id
                    matched += 1
                    continue

            # Unmatched → suspense
            line.match_status = StatementMatchStatus.SUSPENSE.value
            group_id = await _post_suspense_ledger(db, line=line, created_by=created_by)
            existing = await db.scalar(
                select(SuspenseItem).where(SuspenseItem.statement_line_id == line.id)
            )
            if existing is None:
                db.add(
                    SuspenseItem(
                        statement_line_id=line.id,
                        provider=line.provider,
                        amount_minor=line.amount_minor,
                        currency=line.currency,
                        reason="no_matching_payment_or_payout",
                        status=SuspenseStatus.OPEN.value,
                        ledger_group_id=group_id,
                    )
                )
            suspense_n += 1
            unmatched += 1
            continue

        pay_amt = to_minor(payment.amount)
        if abs(pay_amt - line.amount_minor) > 1:
            line.match_status = StatementMatchStatus.SUSPENSE.value
            group_id = await _post_suspense_ledger(db, line=line, created_by=created_by)
            existing = await db.scalar(
                select(SuspenseItem).where(SuspenseItem.statement_line_id == line.id)
            )
            if existing is None:
                db.add(
                    SuspenseItem(
                        statement_line_id=line.id,
                        provider=line.provider,
                        amount_minor=line.amount_minor,
                        currency=line.currency,
                        reason=f"amount_mismatch payment={pay_amt} statement={line.amount_minor}",
                        status=SuspenseStatus.OPEN.value,
                        ledger_group_id=group_id,
                    )
                )
            suspense_n += 1
            unmatched += 1
            continue

        line.match_status = StatementMatchStatus.MATCHED.value
        line.matched_payment_id = payment.id
        matched += 1

    run.lines_total = len(lines)
    run.matched = matched
    run.unmatched = unmatched
    run.suspense = suspense_n
    run.status = ReconciliationRunStatus.COMPLETED.value
    run.finished_at = datetime.now(timezone.utc)
    run.summary = {
        "batch_id": str(batch.id),
        "matched": matched,
        "unmatched": unmatched,
        "suspense": suspense_n,
    }
    await db.flush()

    suspense_bal = await account_balance_minor(
        db, LedgerAccountType.SUSPENSE.value, all_accounts=True
    )
    threshold = get_settings().suspense_alert_threshold_minor
    if suspense_bal >= threshold:
        db.add(
            AuditLog(
                actor_id=None,
                action="SUSPENSE_THRESHOLD_EXCEEDED",
                entity_type="suspense",
                entity_id=None,
                metadata_json={
                    "balance_minor": suspense_bal,
                    "threshold_minor": threshold,
                    "run_id": str(run.id),
                },
            )
        )
        await db.flush()

    return run


async def run_daily_reconciliation(
    db: AsyncSession,
    *,
    provider: str = "MTN",
    created_by: str = "system",
    include_orphan: bool = False,
) -> dict:
    batch = await build_synthetic_statement(
        db,
        provider=provider,
        hours=48,
        include_orphan=include_orphan,
        created_by=created_by,
    )
    run = await match_batch(db, batch, created_by=created_by)
    return {
        "batch_id": str(batch.id),
        "run_id": str(run.id),
        "matched": run.matched,
        "unmatched": run.unmatched,
        "suspense": run.suspense,
        "lines_total": run.lines_total,
    }


async def list_suspense(
    db: AsyncSession,
    *,
    status: str | None = SuspenseStatus.OPEN.value,
    page: int = 1,
    page_size: int = 50,
) -> tuple[list[SuspenseItem], int]:
    q = select(SuspenseItem).order_by(SuspenseItem.created_at.desc())
    cq = select(func.count()).select_from(SuspenseItem)
    if status:
        q = q.where(SuspenseItem.status == status)
        cq = cq.where(SuspenseItem.status == status)
    total = int(await db.scalar(cq) or 0)
    rows = list(
        (await db.scalars(q.offset((page - 1) * page_size).limit(page_size))).all()
    )
    return rows, total


async def resolve_suspense(
    db: AsyncSession,
    admin: User,
    suspense_id: UUID,
    *,
    notes: str,
    action: str = "write_off",
) -> SuspenseItem:
    """
    Resolve an open suspense item.
    action=write_off → reverse suspense ledger (clearing ↔ suspense).
    action=ignore → mark resolved without ledger move (line already parked).
    """
    item = await db.get(SuspenseItem, suspense_id)
    if not item:
        raise HTTPException(status_code=404, detail="Suspense item not found")
    if item.status == SuspenseStatus.RESOLVED.value:
        return item

    before = {"status": item.status, "amount_minor": item.amount_minor}
    group_id = item.ledger_group_id

    if action == "write_off" and item.amount_minor > 0:
        # Reverse the suspense parking entry
        group_id = await post_group(
            db,
            legs=[
                LedgerLeg(
                    account_type=LedgerAccountType.SUSPENSE.value,
                    direction=LedgerDirection.DEBIT.value,
                    amount_minor=item.amount_minor,
                    leg_key="suspense_clear",
                ),
                LedgerLeg(
                    account_type=LedgerAccountType.PROVIDER_CLEARING.value,
                    direction=LedgerDirection.CREDIT.value,
                    amount_minor=item.amount_minor,
                    leg_key="clearing_clear",
                ),
            ],
            source_type="adjustment",
            source_id=item.id,
            idempotency_prefix=f"suspense:resolve:{item.id}",
            created_by=f"admin:{admin.id}",
            notes=notes,
            currency=item.currency,
        )

    item.status = SuspenseStatus.RESOLVED.value
    item.resolved_by = admin.id
    item.resolved_at = datetime.now(timezone.utc)
    item.resolution_notes = notes
    if group_id:
        item.ledger_group_id = group_id

    line = await db.get(ProviderStatementLine, item.statement_line_id)
    if line:
        line.match_status = StatementMatchStatus.IGNORED.value

    db.add(
        AuditLog(
            actor_id=admin.id,
            action="SUSPENSE_RESOLVED",
            entity_type="suspense_item",
            entity_id=item.id,
            metadata_json={
                "before": before,
                "after": {"status": item.status, "action": action},
                "notes": notes,
            },
        )
    )
    await db.flush()
    return item


async def list_payout_queue(
    db: AsyncSession,
    *,
    page: int = 1,
    page_size: int = 50,
) -> tuple[list[MerchantPayout], int]:
    """PENDING/PROCESSING payouts — entitlements awaiting execute (Phase C)."""
    open_statuses = {PayoutStatus.PENDING.value, PayoutStatus.PROCESSING.value}
    cq = select(func.count()).select_from(MerchantPayout).where(
        MerchantPayout.status.in_(open_statuses)
    )
    total = int(await db.scalar(cq) or 0)
    rows = list(
        (
            await db.scalars(
                select(MerchantPayout)
                .where(MerchantPayout.status.in_(open_statuses))
                .order_by(MerchantPayout.created_at.asc())
                .offset((page - 1) * page_size)
                .limit(page_size)
            )
        ).all()
    )
    return rows, total
