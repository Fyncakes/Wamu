"""Unit tests for commission engine (integer UGX)."""

from __future__ import annotations

from decimal import Decimal
from uuid import uuid4

from app.models.order import Order
from app.services.commission import (
    bps_of,
    compute_for_order,
    proportional_refund,
    to_minor,
)


def _order(*, subtotal: str, delivery: str = "0") -> Order:
    sub = Decimal(subtotal)
    fee = Decimal(delivery)
    return Order(
        id=uuid4(),
        customer_id=uuid4(),
        business_id=uuid4(),
        subtotal=sub,
        delivery_fee=fee,
        total=sub + fee,
        currency="UGX",
        fulfillment="DELIVERY" if fee > 0 else "PICKUP",
    )


def test_to_minor_and_bps():
    assert to_minor(Decimal("50000.99")) == 50000
    assert bps_of(50000, 250) == 1250  # 2.5%
    assert bps_of(55000, 150) == 825  # 1.5%


def test_single_merchant_2_5_percent():
    # Brief-style numbers with 2.5% (not 5%)
    order = _order(subtotal="50000", delivery="5000")
    bd = compute_for_order(order, platform_fee_bps=250, provider_fee_bps=150)
    assert bd.gross_minor == 50000
    assert bd.delivery_minor == 5000
    assert bd.customer_total_minor == 55000
    assert bd.commission_minor == 1250
    assert bd.merchant_net_minor == 48750
    assert bd.provider_fee_minor == 825
    assert bd.rider_payable_minor == 5000


def test_pickup_no_rider():
    order = _order(subtotal="10000", delivery="0")
    bd = compute_for_order(order, platform_fee_bps=250, provider_fee_bps=150)
    assert bd.rider_payable_minor == 0
    assert bd.commission_minor == 250
    assert bd.merchant_net_minor == 9750


def test_proportional_partial_refund_retains_rider():
    order = _order(subtotal="50000", delivery="5000")
    original = compute_for_order(order, platform_fee_bps=250, provider_fee_bps=150)
    half = proportional_refund(
        original, refund_subtotal_minor=25000, retain_rider=True
    )
    assert half.gross_minor == 25000
    assert half.commission_minor == 625
    assert half.merchant_net_minor == 24375
    assert half.rider_payable_minor == 0
    assert half.delivery_minor == 0


def test_negative_bps_clamped_and_bps_of_edges():
    assert bps_of(0, 250) == 0
    assert bps_of(100, 0) == 0
    order = _order(subtotal="1000", delivery="0")
    bd = compute_for_order(order, platform_fee_bps=-5, provider_fee_bps=-1)
    assert bd.commission_bps == 0
    assert bd.provider_fee_bps == 0
    assert bd.merchant_net_minor == 1000


def test_tiny_order_refuses_full_fee():
    order = _order(subtotal="1", delivery="0")
    bd = compute_for_order(order, platform_fee_bps=10000, provider_fee_bps=0)
    assert bd.commission_minor == 0
    assert bd.merchant_net_minor == 1


def test_total_mismatch_falls_back_to_sum():
    order = _order(subtotal="10000", delivery="1000")
    order.total = Decimal("99999")  # violate integrity intentionally in memory
    bd = compute_for_order(order, platform_fee_bps=250, provider_fee_bps=150)
    assert bd.customer_total_minor == 11000


def test_proportional_zero_gross():
    order = _order(subtotal="0", delivery="0")
    order.total = Decimal("0")
    original = compute_for_order(order, platform_fee_bps=250, provider_fee_bps=0)
    out = proportional_refund(original, refund_subtotal_minor=0, retain_rider=False)
    assert out.merchant_net_minor == 0
    assert out.commission_minor == 0
