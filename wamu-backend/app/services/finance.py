"""Merchant + admin finance read models derived from ledger + payouts."""

from __future__ import annotations

import csv
import io
from datetime import datetime
from uuid import UUID

from fastapi import HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.business import Business
from app.models.ledger import LedgerAccountType, LedgerDirection, LedgerEntry, LedgerSourceType
from app.models.order import Order, OrderStatus
from app.models.payout import MerchantPayout, PayoutStatus
from app.models.user import User
from app.schemas.finance import (
    AdminFinanceOverview,
    FinanceLedgerPage,
    FinanceSummaryResponse,
    LedgerEntryResponse,
)
from app.services import ledger as ledger_service


async def _require_business_owner(
    db: AsyncSession, user: User, business_id: UUID
) -> Business:
    business = await db.get(Business, business_id)
    if not business:
        raise HTTPException(status_code=404, detail="Business not found")
    if business.owner_id != user.id and user.role != "ADMIN":
        raise HTTPException(status_code=403, detail="Forbidden")
    return business


async def merchant_finance_summary(
    db: AsyncSession, user: User, business_id: UUID
) -> FinanceSummaryResponse:
    await _require_business_owner(db, user, business_id)

    merchant_credits = await ledger_service.sum_account_credits(
        db, LedgerAccountType.MERCHANT_PAYABLE.value, account_id=business_id
    )
    merchant_debits = await ledger_service.sum_account_debits(
        db, LedgerAccountType.MERCHANT_PAYABLE.value, account_id=business_id
    )
    outstanding = merchant_credits - merchant_debits

    # Commission attributed to this merchant's paid orders (from notes/source)
    # Approximate: credits on wamu_commission whose entry_group shares order source
    # with this business's merchant_payable credits.
    commission = await _commission_for_business(db, business_id)
    provider_fees = await _provider_fees_for_business(db, business_id)
    delivery = await _delivery_for_business(db, business_id)

    completed = (
        await db.scalar(
            select(func.count())
            .select_from(Order)
            .where(
                Order.business_id == business_id,
                Order.status.notin_(
                    [OrderStatus.PENDING.value, OrderStatus.CANCELLED.value]
                ),
            )
        )
        or 0
    )

    settled = (
        await db.scalar(
            select(func.coalesce(func.sum(MerchantPayout.amount), 0)).where(
                MerchantPayout.business_id == business_id,
                MerchantPayout.status == PayoutStatus.SUCCESS.value,
            )
        )
        or 0
    )
    pending_payouts = (
        await db.scalar(
            select(func.coalesce(func.sum(MerchantPayout.amount), 0)).where(
                MerchantPayout.business_id == business_id,
                MerchantPayout.status.in_(
                    [PayoutStatus.PENDING.value, PayoutStatus.PROCESSING.value]
                ),
            )
        )
        or 0
    )

    sales_gross = merchant_credits + commission  # net + commission = subtotal credits
    # Refunds only — payout settlements also DEBIT merchant_payable (source=payout)
    refunds = int(
        await db.scalar(
            select(func.coalesce(func.sum(LedgerEntry.amount_minor), 0)).where(
                LedgerEntry.account_type == LedgerAccountType.MERCHANT_PAYABLE.value,
                LedgerEntry.account_id == business_id,
                LedgerEntry.direction == LedgerDirection.DEBIT.value,
                LedgerEntry.source_type == LedgerSourceType.REFUND.value,
            )
        )
        or 0
    )

    return FinanceSummaryResponse(
        business_id=business_id,
        sales_gross_minor=int(sales_gross),
        completed_orders=int(completed),
        refunds_minor=refunds,
        commission_minor=int(commission),
        provider_fees_est_minor=int(provider_fees),
        delivery_fees_minor=int(delivery),
        merchant_net_minor=int(merchant_credits - refunds),
        settled_minor=int(settled),
        outstanding_minor=int(outstanding),
        pending_payouts_minor=int(pending_payouts),
    )


async def _order_ids_for_business(db: AsyncSession, business_id: UUID) -> list[UUID]:
    rows = await db.scalars(select(Order.id).where(Order.business_id == business_id))
    return list(rows.all())


async def _commission_for_business(db: AsyncSession, business_id: UUID) -> int:
    order_ids = await _order_ids_for_business(db, business_id)
    if not order_ids:
        return 0
    return int(
        await db.scalar(
            select(func.coalesce(func.sum(LedgerEntry.amount_minor), 0)).where(
                LedgerEntry.account_type == LedgerAccountType.WAMU_COMMISSION.value,
                LedgerEntry.direction == LedgerDirection.CREDIT.value,
                LedgerEntry.source_type == LedgerSourceType.ORDER.value,
                LedgerEntry.source_id.in_(order_ids),
            )
        )
        or 0
    )


async def _provider_fees_for_business(db: AsyncSession, business_id: UUID) -> int:
    order_ids = await _order_ids_for_business(db, business_id)
    if not order_ids:
        return 0
    return int(
        await db.scalar(
            select(func.coalesce(func.sum(LedgerEntry.amount_minor), 0)).where(
                LedgerEntry.account_type == LedgerAccountType.WAMU_PROVIDER_FEES.value,
                LedgerEntry.direction == LedgerDirection.DEBIT.value,
                LedgerEntry.source_type == LedgerSourceType.ORDER.value,
                LedgerEntry.source_id.in_(order_ids),
            )
        )
        or 0
    )


async def _delivery_for_business(db: AsyncSession, business_id: UUID) -> int:
    order_ids = await _order_ids_for_business(db, business_id)
    if not order_ids:
        return 0
    return int(
        await db.scalar(
            select(func.coalesce(func.sum(LedgerEntry.amount_minor), 0)).where(
                LedgerEntry.account_type == LedgerAccountType.RIDER_PAYABLE.value,
                LedgerEntry.direction == LedgerDirection.CREDIT.value,
                LedgerEntry.source_type == LedgerSourceType.ORDER.value,
                LedgerEntry.source_id.in_(order_ids),
            )
        )
        or 0
    )


async def merchant_finance_ledger(
    db: AsyncSession,
    user: User,
    business_id: UUID,
    *,
    page: int = 1,
    page_size: int = 50,
    since: datetime | None = None,
    until: datetime | None = None,
) -> FinanceLedgerPage:
    await _require_business_owner(db, user, business_id)
    rows, total = await ledger_service.list_entries(
        db,
        account_type=LedgerAccountType.MERCHANT_PAYABLE.value,
        account_id=business_id,
        since=since,
        until=until,
        page=page,
        page_size=page_size,
    )
    return FinanceLedgerPage(
        items=[LedgerEntryResponse.model_validate(r) for r in rows],
        total=total,
        page=page,
        page_size=page_size,
    )


async def admin_finance_overview(db: AsyncSession) -> AdminFinanceOverview:
    # Gross customer payments posted to clearing (debits)
    gmv = await ledger_service.sum_account_debits(
        db, LedgerAccountType.PROVIDER_CLEARING.value
    )

    open_payout = {PayoutStatus.PENDING.value, PayoutStatus.PROCESSING.value}
    queue_count = int(
        await db.scalar(
            select(func.count())
            .select_from(MerchantPayout)
            .where(MerchantPayout.status.in_(open_payout))
        )
        or 0
    )
    queue_minor = int(
        await db.scalar(
            select(func.coalesce(func.sum(MerchantPayout.amount), 0)).where(
                MerchantPayout.status.in_(open_payout)
            )
        )
        or 0
    )

    return AdminFinanceOverview(
        gmv_minor=gmv,
        commission_earned_minor=await ledger_service.account_balance_minor(
            db, LedgerAccountType.WAMU_COMMISSION.value, all_accounts=True
        ),
        provider_fees_est_minor=await ledger_service.sum_account_debits(
            db, LedgerAccountType.WAMU_PROVIDER_FEES.value
        ),
        merchant_payable_minor=await ledger_service.account_balance_minor(
            db, LedgerAccountType.MERCHANT_PAYABLE.value, all_accounts=True
        ),
        rider_payable_minor=await ledger_service.account_balance_minor(
            db, LedgerAccountType.RIDER_PAYABLE.value, all_accounts=True
        ),
        refunds_minor=int(
            await db.scalar(
                select(func.coalesce(func.sum(LedgerEntry.amount_minor), 0)).where(
                    LedgerEntry.account_type
                    == LedgerAccountType.MERCHANT_PAYABLE.value,
                    LedgerEntry.direction == LedgerDirection.DEBIT.value,
                    LedgerEntry.source_type == LedgerSourceType.REFUND.value,
                )
            )
            or 0
        ),
        settled_to_merchants_minor=int(
            await db.scalar(
                select(func.coalesce(func.sum(MerchantPayout.amount), 0)).where(
                    MerchantPayout.status == PayoutStatus.SUCCESS.value
                )
            )
            or 0
        ),
        suspense_minor=await ledger_service.account_balance_minor(
            db, LedgerAccountType.SUSPENSE.value, all_accounts=True
        ),
        payout_queue_count=queue_count,
        payout_queue_minor=queue_minor,
    )


async def admin_finance_ledger(
    db: AsyncSession,
    *,
    account_type: str | None = None,
    account_id: UUID | None = None,
    source_type: str | None = None,
    since: datetime | None = None,
    until: datetime | None = None,
    page: int = 1,
    page_size: int = 50,
) -> FinanceLedgerPage:
    rows, total = await ledger_service.list_entries(
        db,
        account_type=account_type,
        account_id=account_id,
        source_type=source_type,
        since=since,
        until=until,
        page=page,
        page_size=page_size,
    )
    return FinanceLedgerPage(
        items=[LedgerEntryResponse.model_validate(r) for r in rows],
        total=total,
        page=page,
        page_size=page_size,
    )


async def merchant_report_csv(
    db: AsyncSession,
    user: User,
    business_id: UUID,
    *,
    report_type: str,
    since: datetime | None,
    until: datetime | None,
) -> str:
    await _require_business_owner(db, user, business_id)
    rows, _ = await ledger_service.list_entries(
        db,
        account_type=LedgerAccountType.MERCHANT_PAYABLE.value,
        account_id=business_id,
        since=since,
        until=until,
        page=1,
        page_size=5000,
    )
    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(
        [
            "report_type",
            "entry_id",
            "entry_group_id",
            "direction",
            "amount_ugx",
            "source_type",
            "source_id",
            "created_at",
            "notes",
        ]
    )
    for r in rows:
        if report_type == "refunds" and r.source_type != LedgerSourceType.REFUND.value:
            continue
        if report_type == "settlements":
            continue  # handled below
        writer.writerow(
            [
                report_type,
                str(r.id),
                str(r.entry_group_id),
                r.direction,
                r.amount_minor,
                r.source_type,
                str(r.source_id),
                r.created_at.isoformat() if r.created_at else "",
                r.notes or "",
            ]
        )
    if report_type == "settlements":
        payouts = await db.scalars(
            select(MerchantPayout)
            .where(MerchantPayout.business_id == business_id)
            .order_by(MerchantPayout.created_at.desc())
            .limit(5000)
        )
        writer.writerow([])
        writer.writerow(
            ["payout_id", "amount_ugx", "platform_fee", "status", "provider", "created_at"]
        )
        for p in payouts:
            if since and p.created_at and p.created_at < since:
                continue
            if until and p.created_at and p.created_at > until:
                continue
            writer.writerow(
                [
                    str(p.id),
                    int(p.amount),
                    int(p.platform_fee),
                    p.status,
                    p.provider,
                    p.created_at.isoformat() if p.created_at else "",
                ]
            )
    return buf.getvalue()


def merchant_report_pdf_bytes(
    *,
    business_name: str,
    summary: FinanceSummaryResponse,
    report_type: str,
) -> bytes:
    """Minimal single-page PDF without heavy deps (PDF 1.4 text objects)."""
    lines = [
        f"Wamu Merchant Report — {report_type}",
        f"Business: {business_name}",
        f"Sales (gross): UGX {summary.sales_gross_minor}",
        f"Commission: UGX {summary.commission_minor}",
        f"Merchant net: UGX {summary.merchant_net_minor}",
        f"Settled: UGX {summary.settled_minor}",
        f"Outstanding: UGX {summary.outstanding_minor}",
        f"Provider fees (est.): UGX {summary.provider_fees_est_minor}",
        f"Delivery fees: UGX {summary.delivery_fees_minor}",
        f"Refunds: UGX {summary.refunds_minor}",
        f"Completed orders: {summary.completed_orders}",
    ]

    def esc(s: str) -> str:
        return s.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")

    content_lines = ["BT", "/F1 11 Tf", "50 780 Td", "14 TL"]
    for i, line in enumerate(lines):
        if i == 0:
            content_lines.append(f"({esc(line)}) Tj")
        else:
            content_lines.append("T*")
            content_lines.append(f"({esc(line)}) Tj")
    content_lines.append("ET")
    stream = "\n".join(content_lines).encode("latin-1", errors="replace")

    objects: list[bytes] = []
    objects.append(b"1 0 obj<< /Type /Catalog /Pages 2 0 R >>endobj\n")
    objects.append(b"2 0 obj<< /Type /Pages /Kids [3 0 R] /Count 1 >>endobj\n")
    objects.append(
        b"3 0 obj<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
        b"/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>endobj\n"
    )
    objects.append(
        f"4 0 obj<< /Length {len(stream)} >>stream\n".encode()
        + stream
        + b"\nendstream\nendobj\n"
    )
    objects.append(
        b"5 0 obj<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>endobj\n"
    )

    out = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for obj in objects:
        offsets.append(len(out))
        out.extend(obj)
    xref_pos = len(out)
    out.extend(f"xref\n0 {len(offsets)}\n".encode())
    out.extend(b"0000000000 65535 f \n")
    for off in offsets[1:]:
        out.extend(f"{off:010d} 00000 n \n".encode())
    out.extend(
        f"trailer<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref_pos}\n%%EOF\n".encode()
    )
    return bytes(out)
