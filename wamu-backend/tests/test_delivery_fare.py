"""Distance-based delivery fare + rider counteroffers."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from decimal import Decimal
from uuid import uuid4

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.database import Base, get_db
from app.core.security import hash_token
from app.main import app
from app.models.business import (
    Business,
    BusinessMember,
    Category,
    MemberRole,
    VerificationStatus,
)
from app.models.product import Product
from app.models.rider import (
    Delivery,
    DeliveryFareOffer,
    DeliveryFareOfferStatus,
    DeliveryStatus,
    RiderProfile,
    RiderStatus,
)
from app.models.user import OtpChallenge, User, UserProfile, UserRole
from app.services.delivery_fare import (
    compute_fare_ugx,
    counteroffer_bounds,
    get_fare_config,
)

TEST_DB = "sqlite+aiosqlite:///:memory:"


def test_fare_math_clamps_and_bounds():
    from app.services.delivery_fare import FareConfig

    cfg = FareConfig(
        base_fee_ugx=Decimal("3000"),
        per_km_ugx=Decimal("1500"),
        min_fee_ugx=Decimal("4000"),
        max_fee_ugx=Decimal("35000"),
        extra_charges_ugx=Decimal("0"),
        counteroffer_min_bps=8000,
        counteroffer_max_bps=15000,
        offer_ttl_seconds=600,
        rider_min_per_km_cap_ugx=Decimal("2500"),
    )
    assert compute_fare_ugx(0, cfg) == Decimal("4000.00")
    assert compute_fare_ugx(2, cfg) == Decimal("6000.00")
    assert compute_fare_ugx(100, cfg) == Decimal("35000.00")
    lo, hi = counteroffer_bounds(Decimal("10000"), cfg)
    assert lo == Decimal("8000.00")
    assert hi == Decimal("15000.00")


@pytest_asyncio.fixture
async def env():
    engine = create_async_engine(TEST_DB, future=True)
    session_factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    async def override_get_db():
        async with session_factory() as session:
            try:
                yield session
                await session.commit()
            except Exception:
                await session.rollback()
                raise

    app.dependency_overrides[get_db] = override_get_db
    transport = ASGITransport(app=app)

    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        async with session_factory() as session:
            for phone in ("+256788800001", "+256788800002", "+256788800003"):
                session.add(
                    OtpChallenge(
                        phone=phone,
                        code_hash=hash_token("123456"),
                        expires_at=datetime.now(timezone.utc) + timedelta(minutes=10),
                    )
                )
            cat = Category(name="Food", slug=f"fare-{uuid4().hex[:6]}", description="t")
            session.add(cat)
            await session.flush()
            owner = User(phone="+256788800001", phone_verified=True, role=UserRole.BUSINESS.value)
            session.add(owner)
            await session.flush()
            session.add(UserProfile(user_id=owner.id, first_name="Shop", last_name="Owner"))
            customer = User(
                phone="+256788800002", phone_verified=True, role=UserRole.CUSTOMER.value
            )
            session.add(customer)
            await session.flush()
            session.add(UserProfile(user_id=customer.id, first_name="Cust", last_name="Omer"))
            rider_user = User(
                phone="+256788800003", phone_verified=True, role=UserRole.CUSTOMER.value
            )
            session.add(rider_user)
            await session.flush()
            session.add(UserProfile(user_id=rider_user.id, first_name="Ri", last_name="Der"))
            biz = Business(
                owner_id=owner.id,
                name="Fare Kitchen",
                slug=f"fare-{uuid4().hex[:6]}",
                category_id=cat.id,
                verification_status=VerificationStatus.VERIFIED.value,
            )
            session.add(biz)
            await session.flush()
            session.add(
                BusinessMember(business_id=biz.id, user_id=owner.id, role=MemberRole.OWNER.value)
            )
            product = Product(
                business_id=biz.id,
                category_id=cat.id,
                name="Fare Meal",
                slug=f"meal-{uuid4().hex[:6]}",
                price=Decimal("10000"),
                currency="UGX",
                stock_quantity=10,
            )
            session.add(product)
            rider = RiderProfile(
                user_id=rider_user.id,
                display_name="Boda Joe",
                wamu_rider_ref=f"WR-{uuid4().hex[:8].upper()}",
                vehicle_type="BODA",
                status=RiderStatus.APPROVED.value,
                available_delivery=True,
            )
            session.add(rider)
            await session.commit()
            ids = {
                "biz_id": str(biz.id),
                "product_id": str(product.id),
                "rider_id": str(rider.id),
            }

        async def _token(phone: str) -> str:
            r = await ac.post(
                "/api/v1/auth/verify-otp", json={"phone": phone, "code": "123456"}
            )
            assert r.status_code == 200, r.text
            return r.json()["access_token"]

        cust_t = await _token("+256788800002")
        rider_t = await _token("+256788800003")
        yield {
            "client": ac,
            "session_factory": session_factory,
            "customer_headers": {"Authorization": f"Bearer {cust_t}"},
            "rider_headers": {"Authorization": f"Bearer {rider_t}"},
            **ids,
        }

    app.dependency_overrides.clear()
    await engine.dispose()


@pytest.mark.asyncio
async def test_quote_and_order_uses_distance_fare(env, monkeypatch):
    from app.services import delivery_fare as fare_mod

    async def fake_quote(db, *, business_id, delivery_address):
        return {
            "business_id": str(business_id),
            "delivery_address": delivery_address,
            "pickup_lat": 0.35,
            "pickup_lng": 32.58,
            "dropoff_lat": 0.36,
            "dropoff_lng": 32.59,
            "distance_km": 2.0,
            "distance_source": "test+osrm",
            "estimated_fare_ugx": 6000.0,
            "currency": "UGX",
            "config": {},
            "counteroffer_min_ugx": 4800.0,
            "counteroffer_max_ugx": 9000.0,
        }

    monkeypatch.setattr(fare_mod, "quote_delivery_fare", fake_quote)

    client = env["client"]
    ch = env["customer_headers"]
    q = await client.post(
        "/api/v1/deliveries/quote",
        headers=ch,
        json={
            "business_id": env["biz_id"],
            "delivery_address": "Nakawa Trading Centre, Kampala",
        },
    )
    assert q.status_code == 200, q.text
    assert q.json()["estimated_fare_ugx"] == 6000.0

    order = await client.post(
        "/api/v1/orders",
        headers=ch,
        json={
            "business_id": env["biz_id"],
            "fulfillment": "DELIVERY",
            "delivery_address": "Nakawa Trading Centre, Kampala",
            "items": [{"product_id": env["product_id"], "quantity": 1}],
        },
    )
    assert order.status_code == 201, order.text
    assert float(order.json()["delivery_fee"]) == 6000.0


@pytest.mark.asyncio
async def test_rider_counteroffer_customer_accept(env, monkeypatch):
    from app.services import delivery_fare as fare_mod

    async def fake_quote(db, *, business_id, delivery_address):
        return {
            "business_id": str(business_id),
            "delivery_address": delivery_address,
            "pickup_lat": 0.35,
            "pickup_lng": 32.58,
            "dropoff_lat": 0.36,
            "dropoff_lng": 32.59,
            "distance_km": 2.0,
            "distance_source": "test",
            "estimated_fare_ugx": 10000.0,
            "currency": "UGX",
            "config": {},
            "counteroffer_min_ugx": 8000.0,
            "counteroffer_max_ugx": 15000.0,
        }

    monkeypatch.setattr(fare_mod, "quote_delivery_fare", fake_quote)

    client = env["client"]
    ch = env["customer_headers"]
    rh = env["rider_headers"]

    order = await client.post(
        "/api/v1/orders",
        headers=ch,
        json={
            "business_id": env["biz_id"],
            "fulfillment": "DELIVERY",
            "delivery_address": "Makerere Hill, Kampala",
            "items": [{"product_id": env["product_id"], "quantity": 1}],
        },
    )
    assert order.status_code == 201, order.text
    order_id = order.json()["id"]

    # Simulate paid delivery row
    async with env["session_factory"]() as session:
        d = Delivery(
            order_id=__import__("uuid").UUID(order_id),
            status=DeliveryStatus.REQUESTED.value,
            pickup_address="Shop",
            dropoff_address="Makerere Hill, Kampala",
            fee=Decimal("10000"),
            estimated_fee=Decimal("10000"),
            agreed_fee=Decimal("10000"),
            distance_km=Decimal("2.000"),
            currency="UGX",
        )
        session.add(d)
        await session.commit()
        delivery_id = str(d.id)

    offer = await client.post(
        f"/api/v1/deliveries/{delivery_id}/fare-offers",
        headers=rh,
        json={"proposed_fee": 12000, "reason": "Heavy traffic"},
    )
    assert offer.status_code == 200, offer.text
    body = offer.json()
    assert body["status"] == "PENDING"
    assert body["proposed_fee"] == 12000.0
    offer_id = body["id"]

    # Out of bounds rejected
    bad = await client.post(
        f"/api/v1/deliveries/{delivery_id}/fare-offers",
        headers=rh,
        json={"proposed_fee": 50000},
    )
    assert bad.status_code in (400, 409)

    ok = await client.post(
        f"/api/v1/deliveries/fare-offers/{offer_id}/accept",
        headers=ch,
    )
    assert ok.status_code == 200, ok.text
    assert ok.json()["status"] == "ACCEPTED"

    async with env["session_factory"]() as session:
        d2 = await session.get(Delivery, __import__("uuid").UUID(delivery_id))
        assert d2 is not None
        assert float(d2.fee) == 12000.0
        assert float(d2.agreed_fee) == 12000.0
        off = await session.get(DeliveryFareOffer, __import__("uuid").UUID(offer_id))
        assert off.status == DeliveryFareOfferStatus.ACCEPTED.value


@pytest.mark.asyncio
async def test_admin_fare_config_roundtrip(env):
    client = env["client"]
    async with env["session_factory"]() as session:
        session.add(
            OtpChallenge(
                phone="+256788800099",
                code_hash=hash_token("123456"),
                expires_at=datetime.now(timezone.utc) + timedelta(minutes=10),
            )
        )
        session.add(
            User(phone="+256788800099", phone_verified=True, role=UserRole.ADMIN.value)
        )
        await session.commit()

    tok = await client.post(
        "/api/v1/auth/verify-otp",
        json={"phone": "+256788800099", "code": "123456"},
    )
    assert tok.status_code == 200, tok.text
    ah = {"Authorization": f"Bearer {tok.json()['access_token']}"}
    got = await client.get("/api/v1/admin/settings/delivery-fare", headers=ah)
    assert got.status_code == 200, got.text
    put = await client.put(
        "/api/v1/admin/settings/delivery-fare",
        headers=ah,
        json={"base_fee_ugx": 3500, "per_km_ugx": 1600},
    )
    assert put.status_code == 200, put.text
    assert put.json()["base_fee_ugx"] == 3500.0


@pytest.mark.asyncio
async def test_fare_offer_expires(env, monkeypatch):
    from app.services import delivery_fare as fare_mod

    async def fake_quote(db, *, business_id, delivery_address):
        return {
            "business_id": str(business_id),
            "delivery_address": delivery_address,
            "pickup_lat": 0.35,
            "pickup_lng": 32.58,
            "dropoff_lat": 0.36,
            "dropoff_lng": 32.59,
            "distance_km": 2.0,
            "distance_source": "test",
            "estimated_fare_ugx": 10000.0,
            "currency": "UGX",
            "config": {},
            "counteroffer_min_ugx": 8000.0,
            "counteroffer_max_ugx": 15000.0,
        }

    monkeypatch.setattr(fare_mod, "quote_delivery_fare", fake_quote)

    client = env["client"]
    ch = env["customer_headers"]
    rh = env["rider_headers"]

    order = await client.post(
        "/api/v1/orders",
        headers=ch,
        json={
            "business_id": env["biz_id"],
            "fulfillment": "DELIVERY",
            "delivery_address": "Ntinda, Kampala",
            "items": [{"product_id": env["product_id"], "quantity": 1}],
        },
    )
    assert order.status_code == 201, order.text
    order_id = order.json()["id"]

    async with env["session_factory"]() as session:
        d = Delivery(
            order_id=__import__("uuid").UUID(order_id),
            status=DeliveryStatus.REQUESTED.value,
            pickup_address="Shop",
            dropoff_address="Ntinda, Kampala",
            fee=Decimal("10000"),
            estimated_fee=Decimal("10000"),
            agreed_fee=Decimal("10000"),
            distance_km=Decimal("2.000"),
            currency="UGX",
        )
        session.add(d)
        await session.commit()
        delivery_id = str(d.id)

    offer = await client.post(
        f"/api/v1/deliveries/{delivery_id}/fare-offers",
        headers=rh,
        json={"proposed_fee": 11000, "reason": "Rain"},
    )
    assert offer.status_code == 200, offer.text
    offer_id = offer.json()["id"]

    async with env["session_factory"]() as session:
        off = await session.get(DeliveryFareOffer, __import__("uuid").UUID(offer_id))
        assert off is not None
        off.expires_at = datetime.now(timezone.utc) - timedelta(seconds=5)
        await session.commit()

    expired = await client.post(
        f"/api/v1/deliveries/fare-offers/{offer_id}/accept",
        headers=ch,
    )
    assert expired.status_code == 400, expired.text

    async with env["session_factory"]() as session:
        off2 = await session.get(DeliveryFareOffer, __import__("uuid").UUID(offer_id))
        assert off2 is not None
        assert off2.status == DeliveryFareOfferStatus.EXPIRED.value


def test_kampala_place_lookup_covers_luteete_gazaya():
    from app.services.geocode import lookup_kampala_place

    assert lookup_kampala_place("Luteete, Gazaya Road") is not None
    assert lookup_kampala_place("Ruharo, Mbarara") is not None
