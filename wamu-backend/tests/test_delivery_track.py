"""Unit tests for delivery track position (customer live map)."""

import uuid
from decimal import Decimal

from app.models.rider import Delivery, DeliveryStatus
from app.services.riders import apply_track_position, _status_track_t


def _delivery(*, status: str) -> Delivery:
    return Delivery(
        order_id=uuid.uuid4(),
        status=status,
        pickup_lat=Decimal("0.3476"),
        pickup_lng=Decimal("32.5825"),
        dropoff_lat=Decimal("0.3556"),
        dropoff_lng=Decimal("32.5885"),
    )


def test_status_track_progresses():
    early = _status_track_t(DeliveryStatus.ACCEPTED.value)
    late = _status_track_t(DeliveryStatus.IN_TRANSIT.value)
    assert early is not None and late is not None
    assert early < late
    assert _status_track_t(DeliveryStatus.DELIVERED.value) == 1.0
    assert _status_track_t(DeliveryStatus.REQUESTED.value) is None


def test_apply_track_moves_toward_customer():
    early = _delivery(status=DeliveryStatus.GOING_TO_PICKUP.value)
    apply_track_position(early)
    late = _delivery(status=DeliveryStatus.IN_TRANSIT.value)
    apply_track_position(late)

    assert early.rider_lat is not None and late.rider_lat is not None
    # Later status should be closer to dropoff latitude (higher in this fixture).
    assert float(late.rider_lat) > float(early.rider_lat)
    # At pickup should be near shop.
    at_shop = _delivery(status=DeliveryStatus.AT_PICKUP.value)
    apply_track_position(at_shop)
    assert abs(float(at_shop.rider_lat) - 0.3476) < 0.001
