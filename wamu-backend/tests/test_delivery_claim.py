"""Rider enroll, open deliveries, and claim — Master Plan delivery ops."""

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
    Location,
    MemberRole,
    VerificationStatus,
)
from app.models.order import Order, OrderItem, OrderStatus
from app.models.product import Product
from app.models.rider import Delivery, DeliveryStatus
from app.models.user import OtpChallenge, User, UserProfile, UserRole

TEST_DB = "sqlite+aiosqlite:///:memory:"


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
            for phone in (
                "+256700000055",
                "+256700000066",
                "+256700000044",
                "+256700000001",
            ):
                session.add(
                    OtpChallenge(
                        phone=phone,
                        code_hash=hash_token("123456"),
                        expires_at=datetime.now(timezone.utc) + timedelta(minutes=10),
                    )
                )
            cat = Category(name="Food", slug=f"food-{uuid4().hex[:6]}", description="t")
            session.add(cat)
            await session.flush()

            admin = User(
                phone="+256700000001", phone_verified=True, role=UserRole.ADMIN.value
            )
            session.add(admin)
            await session.flush()
            session.add(UserProfile(user_id=admin.id, first_name="Admin"))

            owner = User(phone="+256700000044", phone_verified=True, role=UserRole.BUSINESS.value)
            session.add(owner)
            await session.flush()
            session.add(UserProfile(user_id=owner.id, first_name="Owner", last_name="Biz"))

            customer = User(
                phone="+256700000055", phone_verified=True, role=UserRole.CUSTOMER.value
            )
            session.add(customer)
            await session.flush()
            session.add(UserProfile(user_id=customer.id, first_name="Cust", last_name="Omer"))

            rider_user = User(
                phone="+256700000066", phone_verified=True, role=UserRole.CUSTOMER.value
            )
            session.add(rider_user)
            await session.flush()
            session.add(UserProfile(user_id=rider_user.id, first_name="Rider", last_name="One"))

            biz = Business(
                owner_id=owner.id,
                name="Pilot Kitchen",
                slug=f"pilot-{uuid4().hex[:6]}",
                description="Food",
                category_id=cat.id,
                verification_status=VerificationStatus.VERIFIED.value,
            )
            session.add(biz)
            await session.flush()
            session.add(
                BusinessMember(business_id=biz.id, user_id=owner.id, role=MemberRole.OWNER.value)
            )
            session.add(
                Location(
                    business_id=biz.id,
                    address_line="Ntinda",
                    city="Kampala",
                    latitude=Decimal("0.3476000"),
                    longitude=Decimal("32.6305000"),
                )
            )
            product = Product(
                business_id=biz.id,
                category_id=cat.id,
                name="Lunch",
                slug=f"lunch-{uuid4().hex[:6]}",
                price=Decimal("15000"),
                currency="UGX",
                stock_quantity=10,
            )
            session.add(product)
            await session.flush()

            order = Order(
                customer_id=customer.id,
                business_id=biz.id,
                status=OrderStatus.CONFIRMED.value,
                fulfillment="DELIVERY",
                delivery_address="Nakawa, Kampala",
                subtotal=Decimal("15000"),
                delivery_fee=Decimal("3000"),
                total=Decimal("18000"),
                currency="UGX",
            )
            session.add(order)
            await session.flush()
            session.add(
                OrderItem(
                    order_id=order.id,
                    product_id=product.id,
                    product_name=product.name,
                    unit_price=product.price,
                    quantity=1,
                    subtotal=product.price,
                )
            )
            delivery = Delivery(
                order_id=order.id,
                rider_id=None,
                status=DeliveryStatus.REQUESTED.value,
                pickup_address="Ntinda, Kampala",
                dropoff_address="Nakawa, Kampala",
                fee=Decimal("3000"),
                currency="UGX",
            )
            session.add(delivery)
            await session.commit()

            delivery_id = str(delivery.id)

        yield {
            "client": ac,
            "customer_phone": "+256700000055",
            "rider_phone": "+256700000066",
            "admin_phone": "+256700000001",
            "delivery_id": delivery_id,
        }

    app.dependency_overrides.clear()
    await engine.dispose()


async def _token(client: AsyncClient, phone: str) -> str:
    r = await client.post("/api/v1/auth/verify-otp", json={"phone": phone, "code": "123456"})
    assert r.status_code == 200, r.text
    return r.json()["access_token"]


@pytest.mark.asyncio
async def test_enroll_claim_open_delivery(env):
    client: AsyncClient = env["client"]
    rider_token = await _token(client, env["rider_phone"])
    headers = {"Authorization": f"Bearer {rider_token}"}

    enroll = await client.post(
        "/api/v1/riders/me",
        headers=headers,
        json={"display_name": "Pilot Rider", "vehicle_type": "BODA"},
    )
    assert enroll.status_code == 201, enroll.text
    assert enroll.json()["display_name"] == "Pilot Rider"
    assert enroll.json()["status"] == "DRAFT"

    admin_token = await _token(client, env["admin_phone"])
    approve = await client.post(
        f"/api/v1/admin/riders/{enroll.json()['id']}/approve",
        headers={"Authorization": f"Bearer {admin_token}"},
        json={"note": "test approve"},
    )
    assert approve.status_code == 200, approve.text
    assert approve.json()["status"] == "APPROVED"

    # Auto-assign on approve may consume the open job.
    mine = await client.get("/api/v1/deliveries/mine", headers=headers)
    assert mine.status_code == 200, mine.text
    if mine.json():
        assert mine.json()[0]["status"] == "ACCEPTED"
        return

    open_jobs = await client.get("/api/v1/deliveries/open", headers=headers)
    assert open_jobs.status_code == 200, open_jobs.text
    assert len(open_jobs.json()) >= 1
    delivery_id = open_jobs.json()[0]["id"]

    claim = await client.post(f"/api/v1/deliveries/{delivery_id}/claim", headers=headers)
    assert claim.status_code == 200, claim.text
    assert claim.json()["status"] == "ACCEPTED"
    assert claim.json()["rider"]["display_name"] == "Pilot Rider"


@pytest.mark.asyncio
async def test_passenger_rides_create_works(env):
    """Phase 5 thin MVP — rides no longer 501 when a rider is available."""
    client: AsyncClient = env["client"]
    rider_token = await _token(client, env["rider_phone"])
    enroll = await client.post(
        "/api/v1/riders/me",
        headers={"Authorization": f"Bearer {rider_token}"},
        json={"display_name": "Pilot Rider", "vehicle_type": "BODA"},
    )
    assert enroll.status_code == 201, enroll.text
    admin_token = await _token(client, env["admin_phone"])
    approve = await client.post(
        f"/api/v1/admin/riders/{enroll.json()['id']}/approve",
        headers={"Authorization": f"Bearer {admin_token}"},
        json={"note": "test approve"},
    )
    assert approve.status_code == 200, approve.text
    token = await _token(client, env["customer_phone"])
    r = await client.post(
        "/api/v1/rides",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "pickup_address": "Ntinda market gate",
            "dropoff_address": "Nakawa trading centre",
        },
    )
    assert r.status_code == 201, r.text
    assert r.json()["status"] in ("ACCEPTED", "REQUESTED")
