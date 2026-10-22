"""Distance-based delivery fare + rider counteroffers (admin-configurable)."""

from __future__ import annotations

import logging
import math
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP
from typing import Any

import httpx
from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.notification import Notification
from app.models.order import Order, OrderStatus
from app.models.rider import Delivery, DeliveryStatus, RiderProfile, RiderStatus
from app.models.user import User
from app.services import app_settings as settings_svc
from app.services.geocode import geocode_kampala_address

logger = logging.getLogger(__name__)

# app_settings keys
KEY_BASE = "delivery.base_fee_ugx"
KEY_PER_KM = "delivery.per_km_ugx"
KEY_MIN = "delivery.min_fee_ugx"
KEY_MAX = "delivery.max_fee_ugx"
KEY_EXTRA = "delivery.extra_charges_ugx"
KEY_COUNTER_MIN_BPS = "delivery.counteroffer_min_bps"  # of estimated (e.g. 8000 = 80%)
KEY_COUNTER_MAX_BPS = "delivery.counteroffer_max_bps"  # e.g. 15000 = 150%
KEY_OFFER_TTL = "delivery.offer_ttl_seconds"
KEY_RIDER_MIN_PER_KM_CAP = "delivery.rider_min_per_km_cap_ugx"

# Sensible Kampala boda defaults (UGX) — overridable by admin without app release.
DEFAULTS = {
    KEY_BASE: "3000",
    KEY_PER_KM: "1500",
    KEY_MIN: "4000",
    KEY_MAX: "35000",
    KEY_EXTRA: "0",
    KEY_COUNTER_MIN_BPS: "8000",
    KEY_COUNTER_MAX_BPS: "15000",
    KEY_OFFER_TTL: "600",
    KEY_RIDER_MIN_PER_KM_CAP: "2500",
}

OSRM_URL = "https://router.project-osrm.org/route/v1/driving/{lon1},{lat1};{lon2},{lat2}"


def _q(amount: Decimal | float | int | str) -> Decimal:
    return Decimal(str(amount)).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


def _haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(min(1.0, math.sqrt(a)))


@dataclass
class FareConfig:
    base_fee_ugx: Decimal
    per_km_ugx: Decimal
    min_fee_ugx: Decimal
    max_fee_ugx: Decimal
    extra_charges_ugx: Decimal
    counteroffer_min_bps: int
    counteroffer_max_bps: int
    offer_ttl_seconds: int
    rider_min_per_km_cap_ugx: Decimal

    def to_dict(self) -> dict[str, Any]:
        return {
            "base_fee_ugx": float(self.base_fee_ugx),
            "per_km_ugx": float(self.per_km_ugx),
            "min_fee_ugx": float(self.min_fee_ugx),
            "max_fee_ugx": float(self.max_fee_ugx),
            "extra_charges_ugx": float(self.extra_charges_ugx),
            "counteroffer_min_bps": self.counteroffer_min_bps,
            "counteroffer_max_bps": self.counteroffer_max_bps,
            "offer_ttl_seconds": self.offer_ttl_seconds,
            "rider_min_per_km_cap_ugx": float(self.rider_min_per_km_cap_ugx),
            "formula": "base + (road_km × per_km) + extra, clamped to [min, max]",
        }


async def get_fare_config(db: AsyncSession) -> FareConfig:
    async def _dec(key: str) -> Decimal:
        return _q(await settings_svc.get_setting(db, key, DEFAULTS[key]))

    async def _int(key: str) -> int:
        raw = await settings_svc.get_setting(db, key, DEFAULTS[key])
        try:
            return int(raw)
        except ValueError:
            return int(DEFAULTS[key])

    cfg = FareConfig(
        base_fee_ugx=await _dec(KEY_BASE),
        per_km_ugx=await _dec(KEY_PER_KM),
        min_fee_ugx=await _dec(KEY_MIN),
        max_fee_ugx=await _dec(KEY_MAX),
        extra_charges_ugx=await _dec(KEY_EXTRA),
        counteroffer_min_bps=max(5000, min(await _int(KEY_COUNTER_MIN_BPS), 10000)),
        counteroffer_max_bps=max(10000, min(await _int(KEY_COUNTER_MAX_BPS), 20000)),
        offer_ttl_seconds=max(120, min(await _int(KEY_OFFER_TTL), 3600)),
        rider_min_per_km_cap_ugx=await _dec(KEY_RIDER_MIN_PER_KM_CAP),
    )
    if cfg.min_fee_ugx > cfg.max_fee_ugx:
        cfg.min_fee_ugx, cfg.max_fee_ugx = cfg.max_fee_ugx, cfg.min_fee_ugx
    if cfg.counteroffer_min_bps > cfg.counteroffer_max_bps:
        cfg.counteroffer_min_bps, cfg.counteroffer_max_bps = (
            cfg.counteroffer_max_bps,
            cfg.counteroffer_min_bps,
        )
    return cfg


async def set_fare_config(
    db: AsyncSession, body: dict[str, Any], *, actor_id: uuid.UUID | None = None
) -> FareConfig:
    mapping = {
        "base_fee_ugx": KEY_BASE,
        "per_km_ugx": KEY_PER_KM,
        "min_fee_ugx": KEY_MIN,
        "max_fee_ugx": KEY_MAX,
        "extra_charges_ugx": KEY_EXTRA,
        "counteroffer_min_bps": KEY_COUNTER_MIN_BPS,
        "counteroffer_max_bps": KEY_COUNTER_MAX_BPS,
        "offer_ttl_seconds": KEY_OFFER_TTL,
        "rider_min_per_km_cap_ugx": KEY_RIDER_MIN_PER_KM_CAP,
    }
    changed: dict[str, Any] = {}
    for field, key in mapping.items():
        if field in body and body[field] is not None:
            await settings_svc.set_setting(db, key, str(body[field]))
            changed[field] = body[field]
    if changed:
        from app.models.audit import AuditLog

        db.add(
            AuditLog(
                actor_id=actor_id,
                action="DELIVERY_FARE_CONFIG_UPDATED",
                entity_type="app_settings",
                entity_id=None,
                metadata_json=changed,
            )
        )
    return await get_fare_config(db)


def compute_fare_ugx(distance_km: float, cfg: FareConfig) -> Decimal:
    km = max(0.0, float(distance_km))
    raw = cfg.base_fee_ugx + (_q(km) * cfg.per_km_ugx) + cfg.extra_charges_ugx
    fare = _q(raw)
    if fare < cfg.min_fee_ugx:
        fare = cfg.min_fee_ugx
    if fare > cfg.max_fee_ugx:
        fare = cfg.max_fee_ugx
    return fare


def counteroffer_bounds(estimated: Decimal, cfg: FareConfig) -> tuple[Decimal, Decimal]:
    lo = _q(estimated * Decimal(cfg.counteroffer_min_bps) / Decimal(10000))
    hi = _q(estimated * Decimal(cfg.counteroffer_max_bps) / Decimal(10000))
    lo = max(lo, cfg.min_fee_ugx)
    hi = min(hi, cfg.max_fee_ugx)
    if lo > hi:
        lo, hi = hi, lo
    return lo, hi


async def road_distance_km(
    *,
    pickup_lat: float,
    pickup_lng: float,
    dropoff_lat: float,
    dropoff_lng: float,
) -> tuple[float, str]:
    """Return (km, source) using OSRM road distance; haversine fallback."""
    url = OSRM_URL.format(
        lon1=pickup_lng, lat1=pickup_lat, lon2=dropoff_lng, lat2=dropoff_lat
    )
    try:
        async with httpx.AsyncClient(timeout=8.0) as client:
            res = await client.get(url, params={"overview": "false"})
            if res.status_code < 300:
                data = res.json()
                routes = data.get("routes") or []
                if routes:
                    meters = float(routes[0].get("distance") or 0)
                    if meters > 0:
                        return meters / 1000.0, "osrm"
    except Exception as exc:
        logger.info("OSRM unavailable, using haversine: %s", exc)
    return (
        _haversine_km(pickup_lat, pickup_lng, dropoff_lat, dropoff_lng),
        "haversine",
    )


async def quote_delivery_fare(
    db: AsyncSession,
    *,
    business_id: uuid.UUID,
    delivery_address: str,
) -> dict[str, Any]:
    from app.models.business import Business, Location

    biz = await db.get(Business, business_id)
    if not biz:
        raise HTTPException(status_code=404, detail="Business not found")
    loc = await db.scalar(
        select(Location).where(Location.business_id == business_id).limit(1)
    )
    # Default Kampala centre if shop has no coords yet
    plat = float(loc.latitude) if loc and loc.latitude is not None else 0.3476
    plng = float(loc.longitude) if loc and loc.longitude is not None else 32.5825
    if loc and (loc.latitude is None or loc.longitude is None):
        geo = await geocode_kampala_address(
            (loc.address_line if loc and loc.address_line else None) or biz.name
        )
        if geo:
            plat, plng = geo[0], geo[1]

    drop = await geocode_kampala_address(delivery_address)
    if not drop:
        # Offset placeholder near shop — still quote with short hop
        dlat, dlng = plat + 0.008, plng + 0.006
        distance_source = "estimate"
    else:
        dlat, dlng = drop[0], drop[1]
        distance_source = "geocoded"

    km, road_source = await road_distance_km(
        pickup_lat=plat, pickup_lng=plng, dropoff_lat=dlat, dropoff_lng=dlng
    )
    cfg = await get_fare_config(db)
    fare = compute_fare_ugx(km, cfg)
    return {
        "business_id": str(business_id),
        "delivery_address": delivery_address,
        "pickup_lat": plat,
        "pickup_lng": plng,
        "dropoff_lat": dlat,
        "dropoff_lng": dlng,
        "distance_km": round(km, 3),
        "distance_source": f"{distance_source}+{road_source}",
        "estimated_fare_ugx": float(fare),
        "currency": "UGX",
        "config": cfg.to_dict(),
        "counteroffer_min_ugx": float(counteroffer_bounds(fare, cfg)[0]),
        "counteroffer_max_ugx": float(counteroffer_bounds(fare, cfg)[1]),
    }


async def default_delivery_fee_for_order(
    db: AsyncSession,
    *,
    business_id: uuid.UUID,
    delivery_address: str | None,
) -> tuple[Decimal, dict[str, Any] | None]:
    """Compute fee for create_order; returns (fee, snapshot)."""
    if not delivery_address or len(delivery_address.strip()) < 8:
        cfg = await get_fare_config(db)
        return cfg.min_fee_ugx, None
    try:
        quote = await quote_delivery_fare(
            db, business_id=business_id, delivery_address=delivery_address.strip()
        )
        snap = {
            "distance_km": quote["distance_km"],
            "distance_source": quote["distance_source"],
            "estimated_fare_ugx": quote["estimated_fare_ugx"],
            "pickup_lat": quote["pickup_lat"],
            "pickup_lng": quote["pickup_lng"],
            "dropoff_lat": quote["dropoff_lat"],
            "dropoff_lng": quote["dropoff_lng"],
            "config": quote["config"],
        }
        return _q(quote["estimated_fare_ugx"]), snap
    except Exception as exc:
        logger.warning("delivery fare quote failed, using min: %s", exc)
        cfg = await get_fare_config(db)
        return cfg.min_fee_ugx, None


# —— Negotiation ——


def _offer_to_dict(offer) -> dict[str, Any]:
    return {
        "id": str(offer.id),
        "delivery_id": str(offer.delivery_id),
        "order_id": str(offer.order_id),
        "rider_id": str(offer.rider_id),
        "proposed_fee": float(offer.proposed_fee),
        "original_fee": float(offer.original_fee),
        "currency": offer.currency,
        "reason": offer.reason,
        "status": offer.status,
        "distance_km": float(offer.distance_km) if offer.distance_km is not None else None,
        "expires_at": offer.expires_at.isoformat() if offer.expires_at else None,
        "resolved_at": offer.resolved_at.isoformat() if offer.resolved_at else None,
        "created_at": offer.created_at.isoformat() if getattr(offer, "created_at", None) else None,
    }


async def _sync_fare_offer_chat_status(db: AsyncSession, offer) -> None:
    """Keep structured FARE_OFFER chat card status in sync (display only)."""
    try:
        import json

        from app.models.chat import Message

        msg = await db.scalar(
            select(Message).where(Message.client_message_id == f"fare-offer-{offer.id}")
        )
        if msg and msg.body:
            data = json.loads(msg.body)
            data["status"] = offer.status
            msg.body = json.dumps(data)
    except Exception:
        logger.debug("fare offer chat sync skipped", exc_info=True)


async def _expire_stale_offers(db: AsyncSession, delivery_id: uuid.UUID) -> None:
    from app.models.audit import AuditLog
    from app.models.rider import DeliveryFareOffer, DeliveryFareOfferStatus, RiderProfile

    now = datetime.now(timezone.utc)
    rows = (
        await db.execute(
            select(DeliveryFareOffer).where(
                DeliveryFareOffer.delivery_id == delivery_id,
                DeliveryFareOffer.status == DeliveryFareOfferStatus.PENDING.value,
            )
        )
    ).scalars().all()
    for row in rows:
        exp = row.expires_at
        if exp.tzinfo is None:
            exp = exp.replace(tzinfo=timezone.utc)
        if exp <= now:
            row.status = DeliveryFareOfferStatus.EXPIRED.value
            row.resolved_at = now
            await _sync_fare_offer_chat_status(db, row)
            rider = await db.get(RiderProfile, row.rider_id)
            if rider:
                db.add(
                    Notification(
                        user_id=rider.user_id,
                        type="FARE_OFFER_EXPIRED",
                        title="Fare offer expired",
                        body=f"Your UGX {row.proposed_fee} offer expired — original fare still applies",
                        data={
                            "offer_id": str(row.id),
                            "delivery_id": str(row.delivery_id),
                            "order_id": str(row.order_id),
                        },
                    )
                )
            order = await db.get(Order, row.order_id)
            if order:
                db.add(
                    Notification(
                        user_id=order.customer_id,
                        type="FARE_OFFER_EXPIRED",
                        title="Fare offer expired",
                        body="The rider's fare offer expired. Original delivery fare still applies.",
                        data={
                            "offer_id": str(row.id),
                            "delivery_id": str(row.delivery_id),
                            "order_id": str(order.id),
                        },
                    )
                )
            db.add(
                AuditLog(
                    actor_id=None,
                    action="DELIVERY_FARE_OFFER_EXPIRED",
                    entity_type="delivery_fare_offer",
                    entity_id=row.id,
                    metadata_json={
                        "delivery_id": str(row.delivery_id),
                        "proposed_fee": float(row.proposed_fee),
                        "original_fee": float(row.original_fee),
                    },
                )
            )


async def _post_fare_offer_chat(db: AsyncSession, offer, delivery: Delivery, order: Order) -> None:
    """Structured FARE_OFFER card in the order conversation (acceptance is API-only)."""
    import json

    from app.models.chat import Message, MessageType
    from app.services.order import find_order_conversation

    convo = await find_order_conversation(db, order)
    if not convo:
        return
    body = json.dumps(
        {
            "offer_id": str(offer.id),
            "delivery_id": str(delivery.id),
            "order_id": str(order.id),
            "proposed_fee": float(offer.proposed_fee),
            "original_fee": float(offer.original_fee),
            "currency": offer.currency,
            "distance_km": float(offer.distance_km) if offer.distance_km is not None else None,
            "reason": offer.reason,
            "status": offer.status,
            "pickup_address": delivery.pickup_address,
            "dropoff_address": delivery.dropoff_address,
            "expires_at": offer.expires_at.isoformat() if offer.expires_at else None,
        }
    )
    # Attribute to the rider so the card appears as an incoming offer for the customer.
    rider_user_id = None
    if delivery.rider is not None:
        rider_user_id = delivery.rider.user_id
    elif delivery.rider_id is not None:
        from app.models.rider import RiderProfile

        rp = await db.get(RiderProfile, delivery.rider_id)
        rider_user_id = rp.user_id if rp else None
    db.add(
        Message(
            conversation_id=convo.id,
            sender_id=rider_user_id or order.customer_id,
            body=body,
            message_type=MessageType.FARE_OFFER.value,
            client_message_id=f"fare-offer-{offer.id}",
            status="SENT",
        )
    )
    convo.last_message_at = datetime.now(timezone.utc)


async def propose_fare_offer(
    db: AsyncSession,
    user: User,
    delivery_id: uuid.UUID,
    *,
    proposed_fee: Decimal,
    reason: str | None = None,
    claim_if_open: bool = True,
) -> dict[str, Any]:
    from app.models.rider import DeliveryFareOffer, DeliveryFareOfferStatus

    rider = await db.scalar(select(RiderProfile).where(RiderProfile.user_id == user.id))
    if not rider or rider.status != RiderStatus.APPROVED.value:
        raise HTTPException(status_code=403, detail="Approved rider required")

    delivery = await db.scalar(
        select(Delivery).options(selectinload(Delivery.rider)).where(Delivery.id == delivery_id)
    )
    if not delivery:
        raise HTTPException(status_code=404, detail="Delivery not found")
    if delivery.status in {
        DeliveryStatus.DELIVERED.value,
        DeliveryStatus.CANCELLED.value,
    }:
        raise HTTPException(status_code=400, detail="Delivery is closed")

    await _expire_stale_offers(db, delivery.id)

    # Claim open job when proposing (locks the delivery to this rider).
    if delivery.rider_id is None:
        if not claim_if_open or delivery.status != DeliveryStatus.REQUESTED.value:
            raise HTTPException(status_code=400, detail="Delivery is not open")
        delivery.rider_id = rider.id
        delivery.status = DeliveryStatus.ACCEPTED.value
        delivery.rider = rider
        rider.delivery_count = (rider.delivery_count or 0) + 1
    elif delivery.rider_id != rider.id:
        raise HTTPException(status_code=403, detail="Not your delivery")

    pending = await db.scalar(
        select(DeliveryFareOffer).where(
            DeliveryFareOffer.delivery_id == delivery.id,
            DeliveryFareOffer.status == DeliveryFareOfferStatus.PENDING.value,
        )
    )
    if pending:
        raise HTTPException(status_code=409, detail="A fare offer is already pending")

    original = _q(delivery.agreed_fee or delivery.estimated_fee or delivery.fee)
    cfg = await get_fare_config(db)
    lo, hi = counteroffer_bounds(original, cfg)
    amount = _q(proposed_fee)
    if amount < lo or amount > hi:
        raise HTTPException(
            status_code=400,
            detail=f"Proposed fare must be between UGX {lo} and UGX {hi}",
        )
    if amount == original:
        raise HTTPException(status_code=400, detail="Proposed fare matches the current fare — accept instead")

    now = datetime.now(timezone.utc)
    offer = DeliveryFareOffer(
        delivery_id=delivery.id,
        order_id=delivery.order_id,
        rider_id=rider.id,
        proposed_fee=amount,
        original_fee=original,
        currency=delivery.currency or "UGX",
        reason=(reason or "").strip()[:500] or None,
        status=DeliveryFareOfferStatus.PENDING.value,
        distance_km=delivery.distance_km,
        expires_at=now + timedelta(seconds=cfg.offer_ttl_seconds),
    )
    db.add(offer)
    await db.flush()

    from app.models.audit import AuditLog

    db.add(
        AuditLog(
            actor_id=user.id,
            action="DELIVERY_FARE_OFFER_PROPOSED",
            entity_type="delivery_fare_offer",
            entity_id=offer.id,
            metadata_json={
                "delivery_id": str(delivery.id),
                "proposed_fee": float(amount),
                "original_fee": float(original),
                "reason": offer.reason,
                "distance_km": float(offer.distance_km) if offer.distance_km is not None else None,
            },
        )
    )

    order = await db.get(Order, delivery.order_id)
    if order:
        db.add(
            Notification(
                user_id=order.customer_id,
                type="FARE_OFFER",
                title="Rider proposed a new delivery fare",
                body=f"UGX {amount} (was UGX {original})",
                data={
                    "offer_id": str(offer.id),
                    "delivery_id": str(delivery.id),
                    "order_id": str(order.id),
                    "proposed_fee": float(amount),
                    "original_fee": float(original),
                },
            )
        )
        await _post_fare_offer_chat(db, offer, delivery, order)
        if order.status in (
            OrderStatus.CONFIRMED.value,
            OrderStatus.PROCESSING.value,
            OrderStatus.READY.value,
            OrderStatus.PENDING.value,
        ):
            order.status = OrderStatus.OUT_FOR_DELIVERY.value
            order.version += 1

    await db.flush()
    return _offer_to_dict(offer)


async def resolve_fare_offer(
    db: AsyncSession,
    user: User,
    offer_id: uuid.UUID,
    *,
    accept: bool,
) -> dict[str, Any]:
    from app.models.rider import DeliveryFareOffer, DeliveryFareOfferStatus

    offer = await db.get(DeliveryFareOffer, offer_id)
    if not offer:
        raise HTTPException(status_code=404, detail="Offer not found")

    order = await db.get(Order, offer.order_id)
    if not order:
        raise HTTPException(status_code=404, detail="Order not found")
    if order.customer_id != user.id and user.role != "ADMIN":
        raise HTTPException(status_code=403, detail="Only the customer can resolve this offer")

    await _expire_stale_offers(db, offer.delivery_id)
    await db.flush()
    await db.refresh(offer)

    if offer.status == DeliveryFareOfferStatus.EXPIRED.value:
        # Persist expiry before 400 — request rollback must not revive PENDING.
        await db.commit()
        raise HTTPException(status_code=400, detail="Offer expired")
    if offer.status != DeliveryFareOfferStatus.PENDING.value:
        raise HTTPException(status_code=400, detail=f"Offer is {offer.status}")

    now = datetime.now(timezone.utc)
    exp = offer.expires_at
    if exp.tzinfo is None:
        exp = exp.replace(tzinfo=timezone.utc)
    if exp <= now:
        offer.status = DeliveryFareOfferStatus.EXPIRED.value
        offer.resolved_at = now
        await _sync_fare_offer_chat_status(db, offer)
        await db.commit()
        raise HTTPException(status_code=400, detail="Offer expired")

    delivery = await db.get(Delivery, offer.delivery_id)
    if not delivery:
        raise HTTPException(status_code=404, detail="Delivery not found")

    offer.resolved_at = now
    offer.resolved_by_id = user.id

    if accept:
        # Post-payment: rider payout uses agreed fee; customer charge stays on order
        # unless still unpaid (rare). Increases after pay are allowed within admin caps
        # and credited as delivery.fee for the rider; surplus/deficit vs order.delivery_fee
        # is Wamu delivery margin (documented limitation until top-up payments exist).
        offer.status = DeliveryFareOfferStatus.ACCEPTED.value
        delivery.agreed_fee = offer.proposed_fee
        delivery.fee = offer.proposed_fee
        from app.models.payment import Payment, PaymentStatus
        paid = await db.scalar(
            select(Payment).where(
                Payment.order_id == order.id,
                Payment.status == PaymentStatus.SUCCESS.value,
            )
        )
        if paid is None:
            order.delivery_fee = offer.proposed_fee
            order.total = _q(order.subtotal + order.delivery_fee)
            order.version += 1
        rider = await db.get(RiderProfile, offer.rider_id)
        if rider:
            db.add(
                Notification(
                    user_id=rider.user_id,
                    type="FARE_OFFER_ACCEPTED",
                    title="Customer accepted your fare",
                    body=f"Agreed delivery fare: UGX {offer.proposed_fee}",
                    data={
                        "offer_id": str(offer.id),
                        "delivery_id": str(delivery.id),
                        "order_id": str(order.id),
                    },
                )
            )
    else:
        offer.status = DeliveryFareOfferStatus.DECLINED.value
        rider = await db.get(RiderProfile, offer.rider_id)
        if rider:
            db.add(
                Notification(
                    user_id=rider.user_id,
                    type="FARE_OFFER_DECLINED",
                    title="Customer declined your fare offer",
                    body=f"Original fare UGX {offer.original_fee} still applies",
                    data={
                        "offer_id": str(offer.id),
                        "delivery_id": str(delivery.id),
                        "order_id": str(order.id),
                    },
                )
            )

    from app.models.audit import AuditLog

    db.add(
        AuditLog(
            actor_id=user.id,
            action=(
                "DELIVERY_FARE_OFFER_ACCEPTED"
                if accept
                else "DELIVERY_FARE_OFFER_DECLINED"
            ),
            entity_type="delivery_fare_offer",
            entity_id=offer.id,
            metadata_json={
                "delivery_id": str(delivery.id),
                "order_id": str(order.id),
                "proposed_fee": float(offer.proposed_fee),
                "original_fee": float(offer.original_fee),
                "agreed_fee": float(delivery.agreed_fee)
                if delivery.agreed_fee is not None
                else None,
            },
        )
    )
    await _sync_fare_offer_chat_status(db, offer)
    await db.flush()

    return _offer_to_dict(offer)


async def apply_fare_snapshot_to_delivery(
    db: AsyncSession, delivery: Delivery, order: Order
) -> None:
    """Fill distance/estimated fields when creating a delivery row."""
    snap = None
    addr = order.delivery_address
    if addr:
        try:
            quote = await quote_delivery_fare(
                db, business_id=order.business_id, delivery_address=addr
            )
            snap = quote
        except Exception as exc:
            logger.info("fare snapshot skipped: %s", exc)
    if snap:
        delivery.distance_km = _q(snap["distance_km"])
        delivery.estimated_fee = _q(snap["estimated_fare_ugx"])
        delivery.agreed_fee = _q(delivery.fee)
        delivery.fare_rule_snapshot = {
            "distance_source": snap.get("distance_source"),
            "config": snap.get("config"),
            "estimated_fare_ugx": snap.get("estimated_fare_ugx"),
        }
        if delivery.pickup_lat is None:
            delivery.pickup_lat = _q(snap["pickup_lat"])


async def update_rider_pricing_prefs(
    db: AsyncSession, user: User, *, preferred_min_per_km_ugx: Decimal | None
) -> dict[str, Any]:
    rider = await db.scalar(select(RiderProfile).where(RiderProfile.user_id == user.id))
    if not rider:
        raise HTTPException(status_code=404, detail="Not enrolled as a rider")
    cfg = await get_fare_config(db)
    if preferred_min_per_km_ugx is None:
        rider.preferred_min_per_km_ugx = None
    else:
        val = _q(preferred_min_per_km_ugx)
        if val < 0 or val > cfg.rider_min_per_km_cap_ugx:
            raise HTTPException(
                status_code=400,
                detail=f"preferred_min_per_km_ugx must be 0–{cfg.rider_min_per_km_cap_ugx}",
            )
        rider.preferred_min_per_km_ugx = val
    await db.flush()
    return {
        "preferred_min_per_km_ugx": float(rider.preferred_min_per_km_ugx)
        if rider.preferred_min_per_km_ugx is not None
        else None,
        "cap_ugx": float(cfg.rider_min_per_km_cap_ugx),
        "platform_rates": cfg.to_dict(),
    }
