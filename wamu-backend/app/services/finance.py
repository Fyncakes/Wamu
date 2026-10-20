"""Merchant + admin finance read models derived from ledger + payouts."""

from __future__ import annotations

import csv
import io
from datetime import datetime, timedelta, timezone
from uuid import UUID

from fastapi import HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.business import Business
from app.models.ledger import LedgerAccountType, LedgerDirection, LedgerEntry, LedgerSourceType
from app.models.order import Order, OrderItem, OrderStatus
from app.models.payment import Payment, PaymentStatus
from app.models.payout import MerchantPayout, PayoutStatus
from app.models.product import Product
from app.models.rider import Delivery
from app.models.user import User
from app.schemas.finance import (
    AdminFinanceOverview,
    AttentionOrder,
    FinanceLedgerPage,
    FinanceSummaryResponse,
    LedgerEntryResponse,
    MerchantDashboardResponse,
    SalesTrendPoint,
)
from app.services import ledger as ledger_service
from app.services.commission import to_minor


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


def _period_bounds(
    period: str,
    date_from: datetime | None,
    date_to: datetime | None,
) -> tuple[datetime, datetime, str]:
    now = datetime.now(timezone.utc)
    until = date_to or now
    if date_from is not None:
        return date_from, until, "custom"
    days = {"7d": 7, "30d": 30, "90d": 90}.get(period, 30)
    label = period if period in {"7d", "30d", "90d"} else "30d"
    return now - timedelta(days=days), until, label


async def merchant_dashboard(
    db: AsyncSession,
    user: User,
    business_id: UUID,
    *,
    period: str = "30d",
    date_from: datetime | None = None,
    date_to: datetime | None = None,
) -> MerchantDashboardResponse:
    """
    Merchant home: sold / earned / needs attention from live DB records.
    Sales = SUCCESS payments only (never pending/failed).
    Net earnings = ledger merchant net after refunds (commission already deducted).
    """
    biz = await _require_business_owner(db, user, business_id)
    since, until, period_label = _period_bounds(period, date_from, date_to)

    # Lifetime settlement position (cash already sent vs still owed)
    summary = await merchant_finance_summary(db, user, business_id)

    # Period-scoped SUCCESS collections (actual money collected — never pending/failed)
    paid_q = (
        select(func.coalesce(func.sum(Payment.amount), 0), func.count(Payment.id))
        .join(Order, Order.id == Payment.order_id)
        .where(
            Order.business_id == business_id,
            Payment.status == PaymentStatus.SUCCESS.value,
            Payment.created_at >= since,
            Payment.created_at <= until,
        )
    )
    paid_row = (await db.execute(paid_q)).one()
    total_sales = to_minor(paid_row[0] or 0)

    paid_order_ids = list(
        (
            await db.scalars(
                select(Payment.order_id)
                .join(Order, Order.id == Payment.order_id)
                .where(
                    Order.business_id == business_id,
                    Payment.status == PaymentStatus.SUCCESS.value,
                    Payment.created_at >= since,
                    Payment.created_at <= until,
                )
            )
        ).all()
    )

    # Period net / fees / refunds from ledger for those paid orders
    period_net = 0
    period_commission = 0
    period_refunds = 0
    if paid_order_ids:
        period_net = int(
            await db.scalar(
                select(func.coalesce(func.sum(LedgerEntry.amount_minor), 0)).where(
                    LedgerEntry.account_type
                    == LedgerAccountType.MERCHANT_PAYABLE.value,
                    LedgerEntry.account_id == business_id,
                    LedgerEntry.direction == LedgerDirection.CREDIT.value,
                    LedgerEntry.source_type == LedgerSourceType.ORDER.value,
                    LedgerEntry.source_id.in_(paid_order_ids),
                )
            )
            or 0
        )
        period_commission = int(
            await db.scalar(
                select(func.coalesce(func.sum(LedgerEntry.amount_minor), 0)).where(
                    LedgerEntry.account_type
                    == LedgerAccountType.WAMU_COMMISSION.value,
                    LedgerEntry.direction == LedgerDirection.CREDIT.value,
                    LedgerEntry.source_type == LedgerSourceType.ORDER.value,
                    LedgerEntry.source_id.in_(paid_order_ids),
                )
            )
            or 0
        )
        period_refunds = int(
            await db.scalar(
                select(func.coalesce(func.sum(LedgerEntry.amount_minor), 0)).where(
                    LedgerEntry.account_type
                    == LedgerAccountType.MERCHANT_PAYABLE.value,
                    LedgerEntry.account_id == business_id,
                    LedgerEntry.direction == LedgerDirection.DEBIT.value,
                    LedgerEntry.source_type == LedgerSourceType.REFUND.value,
                    LedgerEntry.source_id.in_(paid_order_ids),
                )
            )
            or 0
        )
        period_net = max(0, period_net - period_refunds)

    # Settled payouts inside the selected window
    period_settled = to_minor(
        await db.scalar(
            select(func.coalesce(func.sum(MerchantPayout.amount), 0)).where(
                MerchantPayout.business_id == business_id,
                MerchantPayout.status == PayoutStatus.SUCCESS.value,
                MerchantPayout.created_at >= since,
                MerchantPayout.created_at <= until,
            )
        )
        or 0
    )

    orders = list(
        (
            await db.scalars(
                select(Order).where(
                    Order.business_id == business_id,
                    Order.created_at >= since,
                    Order.created_at <= until,
                )
            )
        ).all()
    )
    by_status: dict[str, int] = {}
    for o in orders:
        by_status[o.status] = by_status.get(o.status, 0) + 1

    pending_statuses = {
        OrderStatus.PENDING.value,
        OrderStatus.CONFIRMED.value,
        OrderStatus.PROCESSING.value,
        OrderStatus.READY.value,
    }
    attention_rows = list(
        (
            await db.scalars(
                select(Order)
                .where(
                    Order.business_id == business_id,
                    Order.status.in_(pending_statuses),
                )
                .order_by(Order.created_at.asc())
                .limit(12)
            )
        ).all()
    )
    attention = [
        AttentionOrder(
            id=o.id,
            status=o.status,
            total_minor=to_minor(o.total),
            currency=o.currency or "UGX",
            created_at=o.created_at,
            customer_note=o.customer_note,
        )
        for o in attention_rows
    ]

    # Daily sales trend from SUCCESS payments
    day_expr = func.date(Payment.created_at)
    trend_rows = (
        await db.execute(
            select(
                day_expr.label("day"),
                func.coalesce(func.sum(Payment.amount), 0),
                func.count(Payment.id),
            )
            .join(Order, Order.id == Payment.order_id)
            .where(
                Order.business_id == business_id,
                Payment.status == PaymentStatus.SUCCESS.value,
                Payment.created_at >= since,
                Payment.created_at <= until,
            )
            .group_by(day_expr)
            .order_by(day_expr)
        )
    ).all()
    sales_trend = [
        SalesTrendPoint(
            period=str(day),
            sales_minor=to_minor(amt or 0),
            orders=int(cnt or 0),
        )
        for day, amt, cnt in trend_rows
    ]

    return MerchantDashboardResponse(
        business_id=business_id,
        business_name=biz.name,
        period=period_label,
        date_from=since,
        date_to=until,
        total_sales_minor=int(total_sales),
        net_earnings_minor=int(period_net),
        settled_minor=int(period_settled),
        outstanding_minor=summary.outstanding_minor,
        commission_minor=int(period_commission),
        refunds_minor=int(period_refunds),
        orders_total=len(orders),
        orders_by_status=by_status,
        pending_action_count=len(attention_rows),
        attention=attention,
        sales_trend=sales_trend,
        data_source="live_database",
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
    """
    Downloadable merchant reports (CSV / Excel-compatible).
    Types: sales | orders | earnings | payments | products | deliveries
    (aliases: settlements→earnings, refunds→earnings filter, commissions→earnings)
    """
    await _require_business_owner(db, user, business_id)
    kind = (report_type or "earnings").lower().strip()
    if kind in {"settlements", "refunds", "commissions"}:
        kind = "earnings"
    buf = io.StringIO()
    writer = csv.writer(buf)

    def _in_range(dt: datetime | None) -> bool:
        if dt is None:
            return True
        if since and dt < since:
            return False
        if until and dt > until:
            return False
        return True

    if kind == "sales":
        # Paid collections only — distinct from the full payments report.
        writer.writerow(
            [
                "sale_date",
                "payment_id",
                "order_id",
                "amount_ugx",
                "provider",
                "payment_status",
                "momo_reference",
            ]
        )
        q = (
            select(Payment)
            .join(Order, Order.id == Payment.order_id)
            .where(
                Order.business_id == business_id,
                Payment.status == PaymentStatus.SUCCESS.value,
            )
            .order_by(Payment.created_at.desc())
            .limit(5000)
        )
        for p in (await db.scalars(q)).all():
            if not _in_range(p.created_at):
                continue
            writer.writerow(
                [
                    p.created_at.isoformat() if p.created_at else "",
                    str(p.id),
                    str(p.order_id),
                    float(p.amount),
                    p.provider,
                    p.status,
                    p.provider_reference or "",
                ]
            )
        return buf.getvalue()

    if kind == "orders":
        writer.writerow(
            [
                "order_id",
                "created_at",
                "status",
                "fulfillment",
                "subtotal_ugx",
                "delivery_fee_ugx",
                "total_ugx",
                "products",
                "quantities",
            ]
        )
        orders = list(
            (
                await db.scalars(
                    select(Order)
                    .options(selectinload(Order.items))
                    .where(Order.business_id == business_id)
                    .order_by(Order.created_at.desc())
                    .limit(2000)
                )
            ).all()
        )
        for o in orders:
            if not _in_range(o.created_at):
                continue
            names = "; ".join(i.product_name for i in (o.items or []))
            qtys = "; ".join(str(i.quantity) for i in (o.items or []))
            writer.writerow(
                [
                    str(o.id),
                    o.created_at.isoformat() if o.created_at else "",
                    o.status,
                    o.fulfillment,
                    float(o.subtotal),
                    float(o.delivery_fee),
                    float(o.total),
                    names,
                    qtys,
                ]
            )
        return buf.getvalue()

    if kind == "payments":
        # All payment attempts (pending/failed/success) + refund flags.
        writer.writerow(
            [
                "payment_id",
                "order_id",
                "provider",
                "amount_ugx",
                "status",
                "reference",
                "created_at",
                "refund_manual",
            ]
        )
        q = (
            select(Payment)
            .join(Order, Order.id == Payment.order_id)
            .where(Order.business_id == business_id)
            .order_by(Payment.created_at.desc())
            .limit(5000)
        )
        for p in (await db.scalars(q)).all():
            if not _in_range(p.created_at):
                continue
            refund = (p.raw_response or {}).get("refund") or {}
            writer.writerow(
                [
                    str(p.id),
                    str(p.order_id),
                    p.provider,
                    float(p.amount),
                    p.status,
                    p.provider_reference or "",
                    p.created_at.isoformat() if p.created_at else "",
                    refund.get("manual_required") or "",
                ]
            )
        return buf.getvalue()

    if kind == "products":
        writer.writerow(
            [
                "product_id",
                "product_name",
                "qty_sold",
                "sales_ugx",
                "unit_price_ugx",
                "stock_quantity",
            ]
        )
        # Aggregate line items for paid/completed-ish orders in range
        items = list(
            (
                await db.scalars(
                    select(OrderItem)
                    .join(Order, Order.id == OrderItem.order_id)
                    .where(
                        Order.business_id == business_id,
                        Order.status.notin_(
                            [OrderStatus.CANCELLED.value, OrderStatus.PENDING.value]
                        ),
                    )
                    .limit(20000)
                )
            ).all()
        )
        # Need order created_at — reload with orders if needed
        order_ids = {i.order_id for i in items}
        order_map = {
            o.id: o
            for o in (
                await db.scalars(select(Order).where(Order.id.in_(order_ids)))
            ).all()
        } if order_ids else {}
        agg: dict[UUID, dict] = {}
        for i in items:
            o = order_map.get(i.order_id)
            if o and not _in_range(o.created_at):
                continue
            row = agg.setdefault(
                i.product_id,
                {"name": i.product_name, "qty": 0, "sales": 0.0, "price": float(i.unit_price)},
            )
            row["qty"] += int(i.quantity)
            row["sales"] += float(i.subtotal)
        products = {
            p.id: p
            for p in (
                await db.scalars(
                    select(Product).where(Product.business_id == business_id)
                )
            ).all()
        }
        for pid, row in sorted(agg.items(), key=lambda x: -x[1]["sales"]):
            stock = products.get(pid)
            writer.writerow(
                [
                    str(pid),
                    row["name"],
                    row["qty"],
                    row["sales"],
                    row["price"],
                    stock.stock_quantity if stock is not None else "",
                ]
            )
        return buf.getvalue()

    if kind == "deliveries":
        writer.writerow(
            [
                "delivery_id",
                "order_id",
                "status",
                "fee_ugx",
                "rider_id",
                "dropoff",
                "created_at",
            ]
        )
        q = (
            select(Delivery)
            .join(Order, Order.id == Delivery.order_id)
            .where(Order.business_id == business_id)
            .order_by(Delivery.created_at.desc())
            .limit(2000)
        )
        for d in (await db.scalars(q)).all():
            if not _in_range(d.created_at):
                continue
            writer.writerow(
                [
                    str(d.id),
                    str(d.order_id),
                    d.status,
                    float(d.fee or 0),
                    str(d.rider_id) if d.rider_id else "",
                    d.dropoff_address or "",
                    d.created_at.isoformat() if d.created_at else "",
                ]
            )
        return buf.getvalue()

    # earnings (default) — ledger + settlements
    summary = await merchant_finance_summary(db, user, business_id)
    writer.writerow(["metric", "amount_ugx"])
    writer.writerow(["gross_sales", summary.sales_gross_minor])
    writer.writerow(["platform_commission", summary.commission_minor])
    writer.writerow(["refunds", summary.refunds_minor])
    writer.writerow(["delivery_fees", summary.delivery_fees_minor])
    writer.writerow(["net_earnings", summary.merchant_net_minor])
    writer.writerow(["settled_to_momo", summary.settled_minor])
    writer.writerow(["outstanding", summary.outstanding_minor])
    writer.writerow([])
    writer.writerow(
        ["payout_id", "net_ugx", "platform_fee", "status", "provider", "payee", "created_at"]
    )
    payouts = await db.scalars(
        select(MerchantPayout)
        .where(MerchantPayout.business_id == business_id)
        .order_by(MerchantPayout.created_at.desc())
        .limit(5000)
    )
    for p in payouts:
        if not _in_range(p.created_at):
            continue
        writer.writerow(
            [
                str(p.id),
                float(p.amount),
                float(p.platform_fee),
                p.status,
                p.provider,
                p.payee_phone,
                p.created_at.isoformat() if p.created_at else "",
            ]
        )
    return buf.getvalue()


def merchant_report_pdf_bytes(
    *,
    business_name: str,
    report_type: str,
    csv_body: str,
    summary: FinanceSummaryResponse | None = None,
) -> bytes:
    """Build a PDF for this report type from its CSV rows (not a shared summary).

    Previously every PDF only printed the earnings summary, so sales/orders/
    products downloads looked identical. Now each type embeds its own table.
    """
    kind = (report_type or "earnings").lower().strip()
    lines: list[str] = [
        f"Wamu Merchant Report — {kind}",
        f"Business: {business_name}",
    ]
    if kind == "earnings" and summary is not None:
        lines.extend(
            [
                f"Sales (gross): UGX {summary.sales_gross_minor}",
                f"Commission: UGX {summary.commission_minor}",
                f"Merchant net: UGX {summary.merchant_net_minor}",
                f"Settled: UGX {summary.settled_minor}",
                f"Outstanding: UGX {summary.outstanding_minor}",
                f"Provider fees (est.): UGX {summary.provider_fees_est_minor}",
                f"Delivery fees: UGX {summary.delivery_fees_minor}",
                f"Refunds: UGX {summary.refunds_minor}",
                f"Completed orders: {summary.completed_orders}",
                "",
                "Payouts / detail:",
            ]
        )
    else:
        lines.append("Detail rows (from this report):")

    # Flatten CSV into readable lines; keep PDF short (first page).
    csv_rows = [r for r in (csv_body or "").splitlines() if r.strip()]
    max_rows = 35 if kind != "earnings" else 20
    for row in csv_rows[:max_rows]:
        # Soften commas for readability in Helvetica text
        lines.append(row.replace(",", " | ")[:110])
    if len(csv_rows) > max_rows:
        lines.append(f"... {len(csv_rows) - max_rows} more rows in the CSV download")

    def esc(s: str) -> str:
        return s.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")

    content_lines = ["BT", "/F1 9 Tf", "40 780 Td", "11 TL"]
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
