"""Pure commission / fee calculation — integer UGX minor units (whole shillings)."""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal, ROUND_DOWN
from uuid import UUID

from app.core.config import get_settings
from app.models.order import Order


def to_minor(value: Decimal | int | float | str) -> int:
    """UGX has no fractional subunit — store whole shillings as int."""
    d = Decimal(str(value)).quantize(Decimal("1"), rounding=ROUND_DOWN)
    return int(d)


def bps_of(amount_minor: int, bps: int) -> int:
    """floor(amount * bps / 10000). Never negative."""
    if amount_minor <= 0 or bps <= 0:
        return 0
    return (amount_minor * int(bps)) // 10000


@dataclass(frozen=True, slots=True)
class CommissionBreakdown:
    """Amounts for one paid order (single merchant). All fields are UGX integers."""

    order_id: UUID
    business_id: UUID
    gross_minor: int  # subtotal
    delivery_minor: int
    customer_total_minor: int
    commission_bps: int
    commission_minor: int
    provider_fee_bps: int
    provider_fee_minor: int
    merchant_net_minor: int
    rider_payable_minor: int
    currency: str = "UGX"

    def as_decimal_net(self) -> Decimal:
        return Decimal(self.merchant_net_minor)

    def as_decimal_fee(self) -> Decimal:
        return Decimal(self.commission_minor)


def compute_for_order(
    order: Order,
    *,
    platform_fee_bps: int | None = None,
    provider_fee_bps: int | None = None,
) -> CommissionBreakdown:
    settings = get_settings()
    commission_bps = (
        settings.platform_fee_bps if platform_fee_bps is None else int(platform_fee_bps)
    )
    provider_bps = (
        settings.provider_fee_bps if provider_fee_bps is None else int(provider_fee_bps)
    )
    if commission_bps < 0:
        commission_bps = 0
    if provider_bps < 0:
        provider_bps = 0

    gross = to_minor(order.subtotal)
    delivery = to_minor(order.delivery_fee)
    customer_total = to_minor(order.total)
    # Prefer integrity constraint; fall back to sum if legacy rows diverge.
    if customer_total != gross + delivery:
        customer_total = gross + delivery

    commission = bps_of(gross, commission_bps)
    if commission >= gross and gross > 0:
        # Never zero out merchant on tiny orders
        commission = 0
        commission_bps = 0

    merchant_net = gross - commission
    provider_fee = bps_of(customer_total, provider_bps)
    rider_payable = delivery  # pickup / zero fee → 0

    return CommissionBreakdown(
        order_id=order.id,
        business_id=order.business_id,
        gross_minor=gross,
        delivery_minor=delivery,
        customer_total_minor=customer_total,
        commission_bps=commission_bps,
        commission_minor=commission,
        provider_fee_bps=provider_bps,
        provider_fee_minor=provider_fee,
        merchant_net_minor=merchant_net,
        rider_payable_minor=rider_payable,
        currency=order.currency or "UGX",
    )


def proportional_refund(
    original: CommissionBreakdown,
    *,
    refund_subtotal_minor: int,
    retain_rider: bool,
) -> CommissionBreakdown:
    """Scale merchant/commission by refunded subtotal; optionally keep rider fee."""
    if original.gross_minor <= 0:
        ratio_num, ratio_den = 0, 1
    else:
        ratio_num = max(0, min(refund_subtotal_minor, original.gross_minor))
        ratio_den = original.gross_minor

    def scale(v: int) -> int:
        if ratio_den == 0:
            return 0
        return (v * ratio_num) // ratio_den

    commission = scale(original.commission_minor)
    merchant_net = scale(original.merchant_net_minor)
    # Keep gross/delivery/customer consistent with scaled pieces
    gross = merchant_net + commission
    delivery = 0 if retain_rider else scale(original.delivery_minor)
    customer_total = gross + delivery
    provider_fee = scale(original.provider_fee_minor)
    rider = 0 if retain_rider else delivery

    return CommissionBreakdown(
        order_id=original.order_id,
        business_id=original.business_id,
        gross_minor=gross,
        delivery_minor=delivery,
        customer_total_minor=customer_total,
        commission_bps=original.commission_bps,
        commission_minor=commission,
        provider_fee_bps=original.provider_fee_bps,
        provider_fee_minor=provider_fee,
        merchant_net_minor=merchant_net,
        rider_payable_minor=rider,
        currency=original.currency,
    )
