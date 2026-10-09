"""Merchant cancel of paid delivery order cancels the delivery job."""

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
from app.models.payment import Payment, PaymentStatus
from app.models.product import Product
from app.models.rider import Delivery, DeliveryStatus, RiderProfile, RiderStatus
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
            for phone in ("+256733300001", "+256733300002", "+256733300003"):
                session.add(
                    OtpChallenge(
                        phone=phone,
                        code_hash=hash_token("123456"),
                        expires_at=datetime.now(timezone.utc) + timedelta(minutes=10),
                    )
                )
            cat = Category(name="Food", slug=f"food-{uuid4().hex[:6]}")
            session.add(cat)
            await session.flush()
            owner = User(
                phone="+256733300001", phone_verified=True, role=UserRole.BUSINESS.value
            )
            customer = User(
                phone="+256733300002", phone_verified=True, role=UserRole.CUSTOMER.value
            )
            rider_user = User(
                phone="+256733300003", phone_verified=True, role=UserRole.CUSTOMER.value
            )
            session.add_all([owner, customer, rider_user])
            await session.flush()
            session.add(UserProfile(user_id=owner.id, first_name="Own"))
            session.add(UserProfile(user_id=customer.id, first_name="Cust"))
            session.add(UserProfile(user_id=rider_user.id, first_name="Ride"))
            biz = Business(
                owner_id=owner.id,
                name="Cancel Kitchen",
                slug=f"ck-{uuid4().hex[:6]}",
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
                    latitude=Decimal("0.35"),
                    longitude=Decimal("32.6"),
                )
            )
            product = Product(
                business_id=biz.id,
                category_id=cat.id,
                name="Meal",
                slug=f"meal-{uuid4().hex[:6]}",
                price=Decimal("10000"),
                currency="UGX",
                stock_quantity=5,
            )
            session.add(product)
            await session.flush()
            order = Order(
                customer_id=customer.id,
                business_id=biz.id,
                status=OrderStatus.CONFIRMED.value,
                fulfillment="DELIVERY",
                delivery_address="Nakawa",
                subtotal=Decimal("10000"),
                delivery_fee=Decimal("3000"),
                total=Decimal("13000"),
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
            session.add(
                Payment(
                    order_id=order.id,
                    user_id=customer.id,
                    amount=Decimal("13000"),
                    currency="UGX",
                    provider="MOCK",
                    provider_reference=f"MOCK-{uuid4().hex[:8]}",
                    idempotency_key=f"idem-{uuid4().hex}",
                    status=PaymentStatus.SUCCESS.value,
                    phone=customer.phone,
                )
            )
            rider = RiderProfile(
                user_id=rider_user.id,
                display_name="Cancel Rider",
                vehicle_type="BODA",
                status=RiderStatus.APPROVED.value,
                wamu_rider_ref=f"WR-{uuid4().hex[:8].upper()}",
            )
            session.add(rider)
            await session.flush()
            delivery = Delivery(
                order_id=order.id,
                rider_id=rider.id,
                status=DeliveryStatus.ACCEPTED.value,
                pickup_address="Ntinda",
                dropoff_address="Nakawa",
                fee=Decimal("3000"),
                currency="UGX",
            )
            session.add(delivery)
            await session.commit()
            yield {
                "client": ac,
                "owner_phone": "+256733300001",
                "order_id": str(order.id),
                "delivery_id": str(delivery.id),
                "session_factory": session_factory,
            }

    app.dependency_overrides.clear()
    await engine.dispose()


async def _token(env, phone: str) -> str:
    sf = env["session_factory"]
    async with sf() as session:
        session.add(
            OtpChallenge(
                phone=phone,
                code_hash=hash_token("123456"),
                expires_at=datetime.now(timezone.utc) + timedelta(minutes=10),
            )
        )
        await session.commit()
    r = await env["client"].post(
        "/api/v1/auth/verify-otp", json={"phone": phone, "code": "123456"}
    )
    assert r.status_code == 200, r.text
    return r.json()["access_token"]


@pytest.mark.asyncio
async def test_merchant_cancel_cancels_delivery(env):
    from uuid import UUID

    tok = await _token(env, env["owner_phone"])
    r = await env["client"].patch(
        f"/api/v1/orders/{env['order_id']}/status",
        headers={"Authorization": f"Bearer {tok}"},
        json={"status": "CANCELLED"},
    )
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "CANCELLED"

    async with env["session_factory"]() as session:
        delivery = await session.get(Delivery, UUID(env["delivery_id"]))
        assert delivery is not None
        assert delivery.status == DeliveryStatus.CANCELLED.value
