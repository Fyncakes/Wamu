"""Finance / ledger API schemas."""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


class LedgerEntryResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    entry_group_id: UUID
    account_type: str
    account_id: UUID | None
    direction: str
    amount_minor: int
    currency: str
    source_type: str
    source_id: UUID
    created_at: datetime | None = None
    created_by: str
    notes: str | None = None


class FinanceSummaryResponse(BaseModel):
    business_id: UUID
    currency: str = "UGX"
    # Gross sales credited via merchant_payable + commission (subtotal)
    sales_gross_minor: int = 0
    completed_orders: int = 0
    refunds_minor: int = 0
    commission_minor: int = 0
    provider_fees_est_minor: int = 0
    delivery_fees_minor: int = 0
    merchant_net_minor: int = 0
    settled_minor: int = 0
    outstanding_minor: int = 0
    pending_payouts_minor: int = 0


class SalesTrendPoint(BaseModel):
    period: str  # YYYY-MM-DD or YYYY-Www
    sales_minor: int = 0
    orders: int = 0


class AttentionOrder(BaseModel):
    id: UUID
    status: str
    total_minor: int
    currency: str = "UGX"
    created_at: datetime | None = None
    customer_note: str | None = None


class MerchantDashboardResponse(BaseModel):
    """Merchant home KPIs — answers sold / earned / needs attention."""

    business_id: UUID
    business_name: str
    currency: str = "UGX"
    period: str = "30d"  # 7d | 30d | 90d | custom
    date_from: datetime | None = None
    date_to: datetime | None = None
    # Only SUCCESS-collected money counts as sales
    total_sales_minor: int = 0
    net_earnings_minor: int = 0
    settled_minor: int = 0
    outstanding_minor: int = 0
    commission_minor: int = 0
    refunds_minor: int = 0
    orders_total: int = 0
    orders_by_status: dict[str, int] = Field(default_factory=dict)
    pending_action_count: int = 0
    attention: list[AttentionOrder] = Field(default_factory=list)
    sales_trend: list[SalesTrendPoint] = Field(default_factory=list)
    # Explicit: live figures from DB, never demo placeholders
    data_source: str = "live_database"


class FinanceLedgerPage(BaseModel):
    items: list[LedgerEntryResponse]
    total: int
    page: int
    page_size: int


class AdminFinanceOverview(BaseModel):
    currency: str = "UGX"
    gmv_minor: int = 0  # customer totals (provider_clearing debits net of fee credits)
    commission_earned_minor: int = 0
    provider_fees_est_minor: int = 0
    merchant_payable_minor: int = 0
    rider_payable_minor: int = 0
    refunds_minor: int = 0
    settled_to_merchants_minor: int = 0
    suspense_minor: int = 0
    payout_queue_count: int = 0
    payout_queue_minor: int = 0


class FinanceReportRequest(BaseModel):
    report_type: str = Field(
        default="earnings",
        description="sales|orders|earnings|payments|products|deliveries",
    )
    date_from: datetime | None = None
    date_to: datetime | None = None


class SuspenseItemResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    statement_line_id: UUID
    provider: str
    amount_minor: int
    currency: str
    reason: str
    status: str
    ledger_group_id: UUID | None = None
    resolved_by: UUID | None = None
    resolved_at: datetime | None = None
    resolution_notes: str | None = None
    created_at: datetime | None = None


class SuspensePage(BaseModel):
    items: list[SuspenseItemResponse]
    total: int
    page: int
    page_size: int


class ResolveSuspenseRequest(BaseModel):
    notes: str = Field(..., min_length=3, max_length=2000)
    action: str = Field(
        default="write_off",
        description="write_off | ignore",
        pattern="^(write_off|ignore)$",
    )


class StatementLineImport(BaseModel):
    external_ref: str
    amount_minor: int | None = None
    amount: float | None = None
    currency: str = "UGX"
    occurred_at: datetime | None = None


class StatementImportRequest(BaseModel):
    provider: str = "MTN"
    lines: list[StatementLineImport] = Field(default_factory=list)
    notes: str | None = None


class ReconciliationRunResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    provider: str
    batch_id: UUID | None = None
    status: str
    lines_total: int
    matched: int
    unmatched: int
    suspense: int
    summary: dict | None = None
    started_at: datetime | None = None
    finished_at: datetime | None = None
    created_by: str


class RunReconciliationRequest(BaseModel):
    provider: str = "MTN"
    include_orphan: bool = False
    hours: int = Field(default=48, ge=1, le=720)


class PayoutQueueItem(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    payment_id: UUID
    order_id: UUID
    business_id: UUID
    amount: float
    platform_fee: float | None = None
    fee_bps: int | None = None
    currency: str | None = None
    provider: str | None = None
    payee_phone: str | None = None
    status: str
    created_at: datetime | None = None


class PayoutQueuePage(BaseModel):
    items: list[PayoutQueueItem]
    total: int
    page: int
    page_size: int
    auto_execute: bool


class ExecutePayoutQueueRequest(BaseModel):
    limit: int = Field(default=50, ge=1, le=200)
    payout_ids: list[UUID] | None = None


class OwnerPayoutRequest(BaseModel):
    amount_minor: int | None = Field(
        default=None,
        description="UGX minor to withdraw; omit for full available commission",
        ge=1,
    )
    notes: str | None = Field(default=None, max_length=500)
    idempotency_key: str | None = Field(default=None, max_length=100)
