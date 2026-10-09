"""Delivery rider network (Master Plan v3 — passenger mobility is Phase 5)."""

from __future__ import annotations

import math
import uuid
from decimal import Decimal

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.business import Business, Location
from app.models.notification import Notification
from app.models.order import Order, OrderStatus
from app.models.rider import Delivery, DeliveryStatus, Ride, RideStatus, RiderProfile, RiderStatus
from app.models.user import User
from app.schemas.discover import DeliveryResponse, RideCreate, RideResponse, RiderResponse
from app.services.geocode import geocode_kampala_address, is_placeholder_dropoff


def _enqueue_rider_push(
    *,
    user_id: uuid.UUID,
    title: str,
    body: str,
    data: dict,
) -> None:
    try:
        from app.workers.tasks import send_push_notification

        try:
            send_push_notification.delay(
                user_id=str(user_id),
                title=title,
                body=body,
                data=data,
            )
        except Exception:
            send_push_notification(
                user_id=str(user_id),
                title=title,
                body=body,
                data=data,
            )
    except Exception:
        pass


async def _notify_rider_job(
    db: AsyncSession,
    *,
    rider: RiderProfile,
    delivery: Delivery,
    order: Order | None,
    assigned: bool,
) -> None:
    """In-app + FCM alert when a delivery job is assigned or open for claim."""
    dropoff = delivery.dropoff_address or (order.delivery_address if order else None) or "customer"
    pickup = delivery.pickup_address or "shop"
    if assigned:
        ntype = "DELIVERY_JOB"
        title = "New delivery assigned"
        body = f"Pickup at {pickup} → {dropoff}"
    else:
        ntype = "DELIVERY_AVAILABLE"
        title = "Delivery job available"
        body = f"Open job: {pickup} → {dropoff}"
    data = {
        "type": ntype,
        "delivery_id": str(delivery.id),
        "order_id": str(delivery.order_id),
        "deep_link": "/deliveries",
    }
    db.add(
        Notification(
            user_id=rider.user_id,
            type=ntype,
            title=title,
            body=body,
            data=data,
        )
    )
    _enqueue_rider_push(user_id=rider.user_id, title=title, body=body, data=data)


async def _notify_available_riders_open_job(
    db: AsyncSession, delivery: Delivery, order: Order | None
) -> None:
    result = await db.execute(
        select(RiderProfile).where(
            RiderProfile.deleted_at.is_(None),
            RiderProfile.status == RiderStatus.APPROVED.value,
            RiderProfile.available_delivery.is_(True),
        )
    )
    for rider in result.scalars().all():
        await _notify_rider_job(
            db, rider=rider, delivery=delivery, order=order, assigned=False
        )


# Delivery status progression aligned with DeliveryStatus model (Master Plan §18.2).
DELIVERY_TRANSITIONS: dict[str, set[str]] = {
    DeliveryStatus.REQUESTED.value: {
        DeliveryStatus.ACCEPTED.value,
        DeliveryStatus.CANCELLED.value,
    },
    DeliveryStatus.ACCEPTED.value: {
        DeliveryStatus.GOING_TO_PICKUP.value,
        DeliveryStatus.CANCELLED.value,
    },
    DeliveryStatus.GOING_TO_PICKUP.value: {
        DeliveryStatus.AT_PICKUP.value,
        DeliveryStatus.CANCELLED.value,
    },
    DeliveryStatus.AT_PICKUP.value: {
        DeliveryStatus.PICKED_UP.value,
        DeliveryStatus.CANCELLED.value,
    },
    DeliveryStatus.PICKED_UP.value: {
        DeliveryStatus.IN_TRANSIT.value,
        DeliveryStatus.CANCELLED.value,
    },
    DeliveryStatus.IN_TRANSIT.value: {DeliveryStatus.DELIVERED.value},
}

# Thin passenger ride FSM (Phase 5 MVP — not full Uber).
RIDE_TRANSITIONS: dict[str, set[str]] = {
    RideStatus.REQUESTED.value: {
        RideStatus.ACCEPTED.value,
        RideStatus.CANCELLED.value,
    },
    RideStatus.ACCEPTED.value: {
        RideStatus.IN_TRANSIT.value,
        RideStatus.CANCELLED.value,
    },
    RideStatus.IN_TRANSIT.value: {RideStatus.COMPLETED.value},
}


def _estimate_kampala_fare(*, pickup: str, dropoff: str) -> Decimal:
    """Flat Kampala boda estimate — no maps SDK."""
    base = Decimal("8000")
    # Longer address strings ≈ farther trip for demo pricing.
    extra = Decimal(max(0, (len(pickup) + len(dropoff) - 40) // 10) * 500)
    return base + extra


def _rider_resp(r: RiderProfile) -> RiderResponse:
    return RiderResponse.model_validate(r)


def _haversine_km(
    lat1: float | None, lng1: float | None, lat2: float | None, lng2: float | None
) -> float | None:
    if lat1 is None or lng1 is None or lat2 is None or lng2 is None:
        return None
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlmb = math.radians(lng2 - lng1)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dlmb / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def _eta_minutes_between(
    lat1: float | None,
    lng1: float | None,
    lat2: float | None,
    lng2: float | None,
    *,
    default: int = 25,
) -> int:
    """Rough boda ETA: ~22 km/h + 5 min buffer."""
    km = _haversine_km(lat1, lng1, lat2, lng2)
    if km is None:
        return default
    return max(8, min(90, int(round((km / 22.0) * 60 + 5))))


def _as_float(v: Decimal | float | None) -> float | None:
    if v is None:
        return None
    return float(v)


def _lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def _status_track_t(status: str) -> float | None:
    """0→1 progress along start→shop→customer for live map demos."""
    return {
        DeliveryStatus.ACCEPTED.value: 0.08,
        DeliveryStatus.GOING_TO_PICKUP.value: 0.28,
        DeliveryStatus.AT_PICKUP.value: 0.48,
        DeliveryStatus.PICKED_UP.value: 0.58,
        DeliveryStatus.IN_TRANSIT.value: 0.82,
        DeliveryStatus.DELIVERED.value: 1.0,
    }.get(status)


def apply_track_position(delivery: Delivery, *, prefer_profile: bool = False) -> None:
    """Place rider pin on the delivery route from status (demo live tracking).

    When prefer_profile is True and the rider profile has coords, keep those
    (real GPS). Otherwise interpolate along shop → customer path.
    """
    plat = _as_float(delivery.pickup_lat)
    plng = _as_float(delivery.pickup_lng)
    dlat = _as_float(delivery.dropoff_lat)
    dlng = _as_float(delivery.dropoff_lng)
    if plat is None or plng is None or dlat is None or dlng is None:
        return

    rider = delivery.rider
    if prefer_profile and rider is not None:
        rlat, rlng = _as_float(rider.lat), _as_float(rider.lng)
        if rlat is not None and rlng is not None:
            delivery.rider_lat = rider.lat
            delivery.rider_lng = rider.lng
            return

    t = _status_track_t(delivery.status)
    if t is None:
        return

    # Approach shop from a short offset, then ride to customer.
    start_lat = plat - 0.0045
    start_lng = plng - 0.0035
    if t <= 0.48:
        u = t / 0.48
        lat = _lerp(start_lat, plat, u)
        lng = _lerp(start_lng, plng, u)
    else:
        u = (t - 0.48) / 0.52
        lat = _lerp(plat, dlat, u)
        lng = _lerp(plng, dlng, u)
    delivery.rider_lat = Decimal(str(round(lat, 6)))
    delivery.rider_lng = Decimal(str(round(lng, 6)))
    if rider is not None:
        rider.lat = delivery.rider_lat
        rider.lng = delivery.rider_lng


def _delivery_resp(d: Delivery, *, shop_name: str | None = None) -> DeliveryResponse:
    data = DeliveryResponse.model_validate(d)
    if d.rider:
        data.rider = _rider_resp(d.rider)
    if shop_name:
        data.shop_name = shop_name
    return data


async def _shop_name_for_delivery(db: AsyncSession, d: Delivery) -> str | None:
    order = await db.get(Order, d.order_id)
    if not order:
        return None
    biz = await db.get(Business, order.business_id)
    return biz.name if biz else None


async def _apply_real_dropoff(
    db: AsyncSession, delivery: Delivery, order: Order | None = None
) -> None:
    """Replace shop-offset placeholder pins with a geocoded customer address."""
    addr = (delivery.dropoff_address or "").strip()
    if not addr:
        order = order or await db.get(Order, delivery.order_id)
        if order:
            addr = (order.delivery_address or "").strip()
            if addr:
                delivery.dropoff_address = addr
    plat = _as_float(delivery.pickup_lat)
    plng = _as_float(delivery.pickup_lng)
    dlat = _as_float(delivery.dropoff_lat)
    dlng = _as_float(delivery.dropoff_lng)
    if not is_placeholder_dropoff(plat, plng, dlat, dlng):
        return
    geo = await geocode_kampala_address(addr or None)
    if geo:
        delivery.dropoff_lat, delivery.dropoff_lng = geo


async def _delivery_resp_async(db: AsyncSession, d: Delivery) -> DeliveryResponse:
    await _apply_real_dropoff(db, d)
    return _delivery_resp(d, shop_name=await _shop_name_for_delivery(db, d))


def _ride_resp(r: Ride) -> RideResponse:
    data = RideResponse.model_validate(r)
    if r.rider:
        data.rider = _rider_resp(r.rider)
    return data


async def get_available_delivery_rider(db: AsyncSession) -> RiderProfile | None:
    """Assign least-loaded approved rider available for delivery."""
    return await db.scalar(
        select(RiderProfile)
        .where(
            RiderProfile.deleted_at.is_(None),
            RiderProfile.status == RiderStatus.APPROVED.value,
            RiderProfile.available_delivery.is_(True),
        )
        .order_by(RiderProfile.delivery_count.asc(), RiderProfile.created_at.desc())
    )


async def get_available_ride_rider(db: AsyncSession) -> RiderProfile | None:
    return await db.scalar(
        select(RiderProfile)
        .where(
            RiderProfile.deleted_at.is_(None),
            RiderProfile.status == RiderStatus.APPROVED.value,
            RiderProfile.available_rides.is_(True),
        )
        .order_by(RiderProfile.ride_count.asc(), RiderProfile.created_at.desc())
    )


# Back-compat alias used by older call sites
get_default_rider = get_available_delivery_rider


async def ensure_delivery_for_paid_order(db: AsyncSession, order: Order) -> Delivery | None:
    """After payment success on DELIVERY orders — request/assign a rider.

    Multi-shop checkout (shared checkout_batch_id): reuse the same rider and
    delivery_batch_id so one route can pick up Shop A → B → C → customer.
    """
    if (order.fulfillment or "").upper() != "DELIVERY":
        return None
    existing = await db.scalar(select(Delivery).where(Delivery.order_id == order.id))
    if existing:
        return existing

    delivery_batch_id = order.checkout_batch_id
    rider = None
    if order.checkout_batch_id is not None:
        sibling = await db.scalar(
            select(Delivery)
            .join(Order, Order.id == Delivery.order_id)
            .where(
                Order.checkout_batch_id == order.checkout_batch_id,
                Delivery.order_id != order.id,
            )
            .limit(1)
        )
        if sibling is not None:
            delivery_batch_id = sibling.delivery_batch_id or order.checkout_batch_id
            if sibling.rider_id is not None:
                rider = await db.get(RiderProfile, sibling.rider_id)

    if rider is None:
        rider = await get_available_delivery_rider(db)
    pickup = None
    plat = plng = None
    dlat = dlng = None
    biz = await db.get(Business, order.business_id)
    if biz:
        loc = await db.scalar(select(Location).where(Location.business_id == biz.id).limit(1))
        if loc:
            pickup = f"{loc.address_line}, {loc.city}" if loc.address_line else loc.city
            plat, plng = loc.latitude, loc.longitude
        else:
            pickup = biz.name

    if plat is not None and plng is not None:
        dlat = Decimal(str(float(plat) + 0.008))
        dlng = Decimal(str(float(plng) + 0.006))

    eta = None
    if rider:
        eta = _eta_minutes_between(
            _as_float(rider.lat),
            _as_float(rider.lng),
            _as_float(plat),
            _as_float(plng),
            default=25,
        )

    delivery = Delivery(
        order_id=order.id,
        rider_id=rider.id if rider else None,
        status=DeliveryStatus.ACCEPTED.value if rider else DeliveryStatus.REQUESTED.value,
        pickup_address=pickup,
        dropoff_address=order.delivery_address,
        pickup_lat=plat,
        pickup_lng=plng,
        dropoff_lat=dlat,
        dropoff_lng=dlng,
        rider_lat=rider.lat if rider else None,
        rider_lng=rider.lng if rider else None,
        fee=order.delivery_fee if order.delivery_fee is not None else Decimal("3000"),
        currency=order.currency or "UGX",
        eta_minutes=eta,
        delivery_batch_id=delivery_batch_id,
    )
    db.add(delivery)
    await _apply_real_dropoff(db, delivery, order)
    if rider:
        rider.delivery_count = (rider.delivery_count or 0) + 1
        db.add(
            Notification(
                user_id=order.customer_id,
                type="DELIVERY_ASSIGNED",
                title=f"{rider.display_name} is on the way",
                body=f"Your rider {rider.display_name} accepted the delivery.",
                data={
                    "order_id": str(order.id),
                    "delivery_id": str(delivery.id),
                    "rider_name": rider.display_name,
                },
            )
        )
        await _notify_rider_job(
            db, rider=rider, delivery=delivery, order=order, assigned=True
        )
        if order.status in (
            OrderStatus.CONFIRMED.value,
            OrderStatus.PROCESSING.value,
            OrderStatus.READY.value,
            OrderStatus.PENDING.value,
        ):
            # Paid + rider assigned → out for delivery operationally.
            if order.status != OrderStatus.OUT_FOR_DELIVERY.value:
                order.status = OrderStatus.OUT_FOR_DELIVERY.value
                order.version += 1
    await db.flush()
    if rider:
        from app.services.order import notify_delivery_status_in_chat

        await notify_delivery_status_in_chat(
            db, order, DeliveryStatus.ACCEPTED.value, rider_name=rider.display_name
        )
    else:
        await _notify_available_riders_open_job(db, delivery, order)
        await db.flush()
    return delivery


async def get_delivery_for_order(db: AsyncSession, user: User, order_id: uuid.UUID) -> DeliveryResponse:
    order = await db.get(Order, order_id)
    if not order:
        raise HTTPException(status_code=404, detail="Order not found")
    if order.customer_id != user.id and user.role != "ADMIN":
        rider_profile = await db.scalar(select(RiderProfile).where(RiderProfile.user_id == user.id))
        delivery_peek = await db.scalar(select(Delivery).where(Delivery.order_id == order_id))
        is_assigned_rider = bool(
            rider_profile and delivery_peek and delivery_peek.rider_id == rider_profile.id
        )
        if not is_assigned_rider:
            from app.services.business import assert_business_member

            await assert_business_member(db, user, order.business_id)
    delivery = await db.scalar(
        select(Delivery)
        .options(selectinload(Delivery.rider))
        .where(Delivery.order_id == order_id)
    )
    if not delivery:
        raise HTTPException(status_code=404, detail="No delivery for this order")
    if delivery.rider and delivery.status not in (
        DeliveryStatus.DELIVERED.value,
        DeliveryStatus.CANCELLED.value,
    ):
        apply_track_position(delivery, prefer_profile=True)
        # Refresh ETA toward dropoff (or pickup if not yet picked up).
        to_lat, to_lng = delivery.dropoff_lat, delivery.dropoff_lng
        if delivery.status in (
            DeliveryStatus.ACCEPTED.value,
            DeliveryStatus.GOING_TO_PICKUP.value,
            DeliveryStatus.AT_PICKUP.value,
        ):
            to_lat, to_lng = delivery.pickup_lat, delivery.pickup_lng
        delivery.eta_minutes = _eta_minutes_between(
            _as_float(delivery.rider_lat),
            _as_float(delivery.rider_lng),
            _as_float(to_lat),
            _as_float(to_lng),
        )
        await db.flush()
    elif delivery.status == DeliveryStatus.DELIVERED.value:
        apply_track_position(delivery, prefer_profile=True)
    return await _delivery_resp_async(db, delivery)


async def advance_delivery(
    db: AsyncSession,
    user: User,
    delivery_id: uuid.UUID,
    status: str,
    *,
    proof_note: str | None = None,
    lat: float | None = None,
    lng: float | None = None,
) -> DeliveryResponse:
    from app.core.metrics import DELIVERY_COMPLETED, ORDER_DELIVERED, metrics

    delivery = await db.scalar(
        select(Delivery).options(selectinload(Delivery.rider)).where(Delivery.id == delivery_id)
    )
    if not delivery:
        raise HTTPException(status_code=404, detail="Delivery not found")
    rider_profile = await db.scalar(select(RiderProfile).where(RiderProfile.user_id == user.id))
    if user.role != "ADMIN" and (not rider_profile or delivery.rider_id != rider_profile.id):
        raise HTTPException(status_code=403, detail="Only the assigned rider can update")

    new_status = status.upper()
    allowed = DELIVERY_TRANSITIONS.get(delivery.status, set())
    if user.role != "ADMIN" and new_status not in allowed:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid delivery transition {delivery.status} → {new_status}",
        )
    if new_status == DeliveryStatus.DELIVERED.value:
        note = (proof_note or "").strip()
        if user.role != "ADMIN" and len(note) < 3:
            raise HTTPException(
                status_code=400,
                detail="Proof of delivery note required (e.g. handed to customer / left at gate)",
            )
        if note:
            delivery.proof_note = note[:500]
    delivery.status = new_status
    if rider_profile:
        if lat is not None and lng is not None:
            rider_profile.lat = Decimal(str(lat))
            rider_profile.lng = Decimal(str(lng))
            delivery.rider_lat = rider_profile.lat
            delivery.rider_lng = rider_profile.lng
        else:
            # Prefer live GPS on the rider profile; only lerp if none yet.
            apply_track_position(delivery, prefer_profile=True)
        if new_status in (
            DeliveryStatus.PICKED_UP.value,
            DeliveryStatus.IN_TRANSIT.value,
        ):
            delivery.eta_minutes = _eta_minutes_between(
                _as_float(delivery.rider_lat),
                _as_float(delivery.rider_lng),
                _as_float(delivery.dropoff_lat),
                _as_float(delivery.dropoff_lng),
                default=18,
            )
        elif new_status not in (
            DeliveryStatus.DELIVERED.value,
            DeliveryStatus.CANCELLED.value,
        ):
            delivery.eta_minutes = _eta_minutes_between(
                _as_float(delivery.rider_lat),
                _as_float(delivery.rider_lng),
                _as_float(delivery.pickup_lat),
                _as_float(delivery.pickup_lng),
            )
    order = await db.get(Order, delivery.order_id)
    if delivery.status == DeliveryStatus.DELIVERED.value:
        if order and order.status != OrderStatus.DELIVERED.value:
            order.status = OrderStatus.DELIVERED.value
            metrics.incr(ORDER_DELIVERED)
        metrics.incr(DELIVERY_COMPLETED)
        delivery.eta_minutes = 0
    await db.flush()
    if order is not None:
        from app.services.order import notify_delivery_status_in_chat

        rider_name = delivery.rider.display_name if delivery.rider else None
        await notify_delivery_status_in_chat(
            db, order, new_status, rider_name=rider_name
        )
    return await _delivery_resp_async(db, delivery)


async def list_riders(db: AsyncSession) -> list[RiderResponse]:
    result = await db.execute(
        select(RiderProfile).where(
            RiderProfile.deleted_at.is_(None),
            RiderProfile.status == RiderStatus.APPROVED.value,
        )
    )
    return [_rider_resp(r) for r in result.scalars().all()]


async def get_my_rider_profile(db: AsyncSession, user: User) -> RiderProfile | None:
    return await db.scalar(
        select(RiderProfile).where(
            RiderProfile.user_id == user.id,
            RiderProfile.deleted_at.is_(None),
        )
    )


async def enroll_as_rider(
    db: AsyncSession,
    user: User,
    *,
    display_name: str,
    vehicle_type: str = "BODA",
    plate_number: str | None = None,
    lat: Decimal | None = None,
    lng: Decimal | None = None,
) -> RiderProfile:
    """Self-enroll for delivery — pending until admin approves (DRAFT)."""
    existing = await get_my_rider_profile(db, user)
    if existing:
        existing.display_name = display_name.strip() or existing.display_name
        existing.vehicle_type = (vehicle_type or existing.vehicle_type).upper()
        if plate_number is not None:
            existing.plate_number = plate_number.strip() or None
        if lat is not None:
            existing.lat = lat
        if lng is not None:
            existing.lng = lng
        if user.profile is not None:
            user.profile.wants_to_ride = True
        # Only live riders keep/refresh availability on re-enroll.
        if existing.status == RiderStatus.APPROVED.value:
            existing.available_delivery = True
            existing.available_rides = True
            await db.flush()
            await assign_open_deliveries_to_rider(db, existing)
        else:
            await db.flush()
        return existing

    from app.services.rider_verification import next_wamu_rider_ref

    ref = await next_wamu_rider_ref(db)

    name = display_name.strip()
    if not name and user.profile is not None:
        parts = [user.profile.first_name or "", user.profile.last_name or ""]
        name = " ".join(p for p in parts if p).strip()
    if not name:
        name = f"Rider {user.phone[-4:]}"

    rider = RiderProfile(
        user_id=user.id,
        display_name=name,
        wamu_rider_ref=ref,
        vehicle_type=(vehicle_type or "BODA").upper(),
        plate_number=(plate_number or "").strip() or None,
        status=RiderStatus.DRAFT.value,
        available_delivery=False,
        available_rides=False,
        lat=lat if lat is not None else Decimal("0.3476000"),
        lng=lng if lng is not None else Decimal("32.5825000"),
    )
    db.add(rider)
    if user.profile is not None:
        user.profile.wants_to_ride = True
    await db.flush()
    from app.core.metrics import RIDER_ENROLLED, metrics

    metrics.incr(RIDER_ENROLLED)
    return rider


async def update_rider_location(
    db: AsyncSession,
    user: User,
    *,
    lat: float,
    lng: float,
) -> RiderProfile:
    rider = await get_my_rider_profile(db, user)
    if not rider:
        raise HTTPException(status_code=404, detail="Not enrolled as a rider")
    rider.lat = Decimal(str(round(lat, 6)))
    rider.lng = Decimal(str(round(lng, 6)))
    # Mirror onto active deliveries so customer map updates immediately.
    active = (
        await db.scalars(
            select(Delivery)
            .options(selectinload(Delivery.rider))
            .where(
                Delivery.rider_id == rider.id,
                Delivery.status.not_in(
                    [DeliveryStatus.DELIVERED.value, DeliveryStatus.CANCELLED.value]
                ),
            )
        )
    ).all()
    for d in active:
        d.rider_lat = rider.lat
        d.rider_lng = rider.lng
    await db.flush()
    return rider


async def list_open_deliveries(db: AsyncSession, user: User) -> list[DeliveryResponse]:
    """Unassigned REQUESTED jobs — visible to enrolled riders."""
    rider = await get_my_rider_profile(db, user)
    if not rider or rider.status != RiderStatus.APPROVED.value:
        raise HTTPException(status_code=403, detail="Enroll as a rider first")
    result = await db.execute(
        select(Delivery)
        .options(selectinload(Delivery.rider))
        .where(
            Delivery.rider_id.is_(None),
            Delivery.status == DeliveryStatus.REQUESTED.value,
        )
        .order_by(Delivery.created_at.asc())
        .limit(50)
    )
    out = []
    for d in result.scalars().all():
        out.append(await _delivery_resp_async(db, d))
    return out


async def claim_delivery(
    db: AsyncSession, user: User, delivery_id: uuid.UUID
) -> DeliveryResponse:
    rider = await get_my_rider_profile(db, user)
    if not rider or rider.status != RiderStatus.APPROVED.value:
        raise HTTPException(status_code=403, detail="Enroll as a rider first")
    if not rider.available_delivery:
        raise HTTPException(status_code=400, detail="Set yourself available for delivery first")

    delivery = await db.scalar(
        select(Delivery).options(selectinload(Delivery.rider)).where(Delivery.id == delivery_id)
    )
    if not delivery:
        raise HTTPException(status_code=404, detail="Delivery not found")
    if delivery.rider_id is not None:
        raise HTTPException(status_code=409, detail="Delivery already claimed")
    if delivery.status != DeliveryStatus.REQUESTED.value:
        raise HTTPException(status_code=400, detail="Delivery is not open for claim")

    delivery.rider_id = rider.id
    delivery.status = DeliveryStatus.ACCEPTED.value
    delivery.rider = rider
    if delivery.dropoff_lat is None and delivery.pickup_lat is not None:
        delivery.dropoff_lat = Decimal(str(float(delivery.pickup_lat) + 0.008))
        delivery.dropoff_lng = Decimal(str(float(delivery.pickup_lng or 0) + 0.006))
    await _apply_real_dropoff(db, delivery)
    apply_track_position(delivery, prefer_profile=True)
    delivery.eta_minutes = _eta_minutes_between(
        _as_float(delivery.rider_lat),
        _as_float(delivery.rider_lng),
        _as_float(delivery.pickup_lat),
        _as_float(delivery.pickup_lng),
    )
    rider.delivery_count = (rider.delivery_count or 0) + 1

    from app.core.metrics import DELIVERY_CLAIMED, metrics

    metrics.incr(DELIVERY_CLAIMED)

    order = await db.get(Order, delivery.order_id)
    if order:
        from app.models.notification import Notification

        db.add(
            Notification(
                user_id=order.customer_id,
                type="DELIVERY_ASSIGNED",
                title=f"{rider.display_name} is on the way",
                body=f"Your rider {rider.display_name} accepted the delivery.",
                data={
                    "order_id": str(order.id),
                    "delivery_id": str(delivery.id),
                    "rider_name": rider.display_name,
                },
            )
        )
        if order.status in (
            OrderStatus.CONFIRMED.value,
            OrderStatus.PROCESSING.value,
            OrderStatus.READY.value,
        ):
            order.status = OrderStatus.OUT_FOR_DELIVERY.value
            order.version += 1

    await db.flush()
    await db.refresh(delivery, attribute_names=["rider"])
    if delivery.rider is None:
        delivery.rider = rider
    if order:
        from app.services.order import notify_delivery_status_in_chat

        await notify_delivery_status_in_chat(
            db, order, DeliveryStatus.ACCEPTED.value, rider_name=rider.display_name
        )
    return await _delivery_resp_async(db, delivery)


async def assign_open_deliveries_to_rider(
    db: AsyncSession, rider: RiderProfile, *, limit: int = 5
) -> int:
    """Auto-assign backlog of unclaimed REQUESTED deliveries (Phase 0 concierge)."""
    if not rider.available_delivery or rider.status != RiderStatus.APPROVED.value:
        return 0
    result = await db.execute(
        select(Delivery)
        .where(
            Delivery.rider_id.is_(None),
            Delivery.status == DeliveryStatus.REQUESTED.value,
        )
        .order_by(Delivery.created_at.asc())
        .limit(limit)
    )
    assigned = 0
    for delivery in result.scalars().all():
        delivery.rider_id = rider.id
        delivery.status = DeliveryStatus.ACCEPTED.value
        delivery.rider_lat = rider.lat
        delivery.rider_lng = rider.lng
        delivery.eta_minutes = _eta_minutes_between(
            _as_float(rider.lat),
            _as_float(rider.lng),
            _as_float(delivery.pickup_lat),
            _as_float(delivery.pickup_lng),
        )
        if delivery.dropoff_lat is None and delivery.pickup_lat is not None:
            delivery.dropoff_lat = Decimal(str(float(delivery.pickup_lat) + 0.008))
            delivery.dropoff_lng = Decimal(str(float(delivery.pickup_lng or 0) + 0.006))
        order = await db.get(Order, delivery.order_id)
        await _apply_real_dropoff(db, delivery, order)
        rider.delivery_count = (rider.delivery_count or 0) + 1
        if order:
            db.add(
                Notification(
                    user_id=order.customer_id,
                    type="DELIVERY_ASSIGNED",
                    title=f"{rider.display_name} is on the way",
                    body=f"Your rider {rider.display_name} accepted the delivery.",
                    data={
                        "order_id": str(order.id),
                        "delivery_id": str(delivery.id),
                        "rider_name": rider.display_name,
                    },
                )
            )
            if order.status in (
                OrderStatus.CONFIRMED.value,
                OrderStatus.PROCESSING.value,
                OrderStatus.READY.value,
            ):
                order.status = OrderStatus.OUT_FOR_DELIVERY.value
                order.version += 1
            from app.services.order import notify_delivery_status_in_chat

            await notify_delivery_status_in_chat(
                db, order, DeliveryStatus.ACCEPTED.value, rider_name=rider.display_name
            )
        await _notify_rider_job(
            db, rider=rider, delivery=delivery, order=order, assigned=True
        )
        assigned += 1
    if assigned:
        await db.flush()
    return assigned


async def list_my_deliveries(db: AsyncSession, user: User) -> list[DeliveryResponse]:
    rider = await get_my_rider_profile(db, user)
    if not rider:
        return []
    result = await db.execute(
        select(Delivery)
        .options(selectinload(Delivery.rider))
        .where(Delivery.rider_id == rider.id)
        .order_by(Delivery.created_at.desc())
        .limit(50)
    )
    out = []
    for d in result.scalars().all():
        out.append(await _delivery_resp_async(db, d))
    return out


async def create_ride(db: AsyncSession, user: User, data: RideCreate) -> RideResponse:
    fare = _estimate_kampala_fare(
        pickup=data.pickup_address.strip(),
        dropoff=data.dropoff_address.strip(),
    )
    rider = await get_available_ride_rider(db)
    ride = Ride(
        customer_id=user.id,
        rider_id=rider.id if rider else None,
        status=RideStatus.ACCEPTED.value if rider else RideStatus.REQUESTED.value,
        pickup_address=data.pickup_address.strip(),
        dropoff_address=data.dropoff_address.strip(),
        pickup_lat=data.pickup_lat,
        pickup_lng=data.pickup_lng,
        dropoff_lat=data.dropoff_lat,
        dropoff_lng=data.dropoff_lng,
        rider_lat=rider.lat if rider else None,
        rider_lng=rider.lng if rider else None,
        fare=fare,
        currency="UGX",
        eta_minutes=18 if rider else None,
    )
    db.add(ride)
    if rider:
        rider.ride_count = (rider.ride_count or 0) + 1
        from app.models.notification import Notification

        db.add(
            Notification(
                user_id=user.id,
                type="RIDE_ASSIGNED",
                title=f"{rider.display_name} accepted your ride",
                body=f"Boda to {data.dropoff_address[:60]}",
                data={"ride_id": str(ride.id)},
            )
        )
    await db.flush()
    ride = await db.scalar(
        select(Ride).options(selectinload(Ride.rider)).where(Ride.id == ride.id)
    )
    assert ride is not None
    return _ride_resp(ride)


async def get_ride(db: AsyncSession, user: User, ride_id: uuid.UUID) -> RideResponse:
    ride = await db.scalar(
        select(Ride).options(selectinload(Ride.rider)).where(Ride.id == ride_id)
    )
    if not ride:
        raise HTTPException(status_code=404, detail="Ride not found")
    rider_profile = await get_my_rider_profile(db, user)
    is_rider = rider_profile is not None and ride.rider_id == rider_profile.id
    if ride.customer_id != user.id and not is_rider and user.role != "ADMIN":
        raise HTTPException(status_code=403, detail="Not your ride")
    return _ride_resp(ride)


async def my_rides(db: AsyncSession, user: User) -> list[RideResponse]:
    result = await db.execute(
        select(Ride)
        .options(selectinload(Ride.rider))
        .where(Ride.customer_id == user.id)
        .order_by(Ride.created_at.desc())
        .limit(50)
    )
    return [_ride_resp(r) for r in result.scalars().all()]


async def list_rider_rides(db: AsyncSession, user: User) -> list[RideResponse]:
    rider = await get_my_rider_profile(db, user)
    if not rider:
        return []
    result = await db.execute(
        select(Ride)
        .options(selectinload(Ride.rider))
        .where(Ride.rider_id == rider.id)
        .order_by(Ride.created_at.desc())
        .limit(50)
    )
    return [_ride_resp(r) for r in result.scalars().all()]


async def advance_ride(
    db: AsyncSession, user: User, ride_id: uuid.UUID, new_status: str
) -> RideResponse:
    ride = await db.scalar(
        select(Ride).options(selectinload(Ride.rider)).where(Ride.id == ride_id)
    )
    if not ride:
        raise HTTPException(status_code=404, detail="Ride not found")
    rider_profile = await get_my_rider_profile(db, user)
    is_rider = rider_profile is not None and ride.rider_id == rider_profile.id
    is_customer = ride.customer_id == user.id
    status = (new_status or "").upper().strip()
    allowed = RIDE_TRANSITIONS.get(ride.status, set())
    if status not in allowed:
        raise HTTPException(
            status_code=400,
            detail=f"Cannot transition ride from {ride.status} to {status}",
        )
    if status == RideStatus.CANCELLED.value:
        if not (is_customer or is_rider or user.role == "ADMIN"):
            raise HTTPException(status_code=403, detail="Not allowed")
    else:
        if not (is_rider or user.role == "ADMIN"):
            raise HTTPException(status_code=403, detail="Only assigned rider can advance")
    ride.status = status
    await db.flush()
    await db.refresh(ride)
    return _ride_resp(ride)
