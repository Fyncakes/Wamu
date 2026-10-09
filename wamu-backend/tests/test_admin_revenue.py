"""Admin revenue / platform fee aggregation."""

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
from app.models.business import Business, BusinessStatus, Category, VerificationStatus
from app.models.order import Order, OrderStatus
from app.models.payment import Payment, PaymentStatus
from app.models.payout import MerchantPayout, PayoutStatus
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
            session.add(
                OtpChallenge(
                    phone="+256700000001",
                    code_hash=hash_token("123456"),
                    expires_at=datetime.now(timezone.utc) + timedelta(minutes=10),
                )
            )
            admin = User(
                phone="+256700000001",
                phone_verified=True,
                role=UserRole.ADMIN.value,
            )
            customer = User(
                phone="+256700000099",
                phone_verified=True,
                role=UserRole.CUSTOMER.value,
            )
            owner = User(
                phone="+256700000088",
                phone_verified=True,
                role=UserRole.BUSINESS.value,
            )
            session.add_all([admin, customer, owner])
            await session.flush()
            session.add(UserProfile(user_id=admin.id, first_name="Admin"))
            cat = Category(name="Rev", slug=f"rev-{uuid4().hex[:6]}")
            session.add(cat)
            await session.flush()
            biz = Business(
                owner_id=owner.id,
                name="Fee Shop",
                slug=f"fee-{uuid4().hex[:6]}",
                category_id=cat.id,
                phone="+256700000088",
                payout_phone="+256700000088",
                status=BusinessStatus.ACTIVE.value,
                verification_status=VerificationStatus.VERIFIED.value,
            )
            session.add(biz)
            await session.flush()
            order = Order(
                customer_id=customer.id,
                business_id=biz.id,
                status=OrderStatus.CONFIRMED.value,
                subtotal=Decimal("10000.00"),
                delivery_fee=Decimal("0"),
                total=Decimal("10000.00"),
                currency="UGX",
                fulfillment="PICKUP",
            )
            session.add(order)
            await session.flush()
            payment = Payment(
                order_id=order.id,
                user_id=customer.id,
                amount=Decimal("10000.00"),
                currency="UGX",
                provider="MOCK",
                provider_reference=f"MOCK-{uuid4().hex[:8]}",
                idempotency_key=f"idem-{uuid4().hex}",
                status=PaymentStatus.SUCCESS.value,
                phone=customer.phone,
            )
            session.add(payment)
            await session.flush()
            session.add(
                MerchantPayout(
                    payment_id=payment.id,
                    order_id=order.id,
                    business_id=biz.id,
                    amount=Decimal("9750.00"),
                    platform_fee=Decimal("250.00"),
                    fee_bps=250,
                    currency="UGX",
                    provider="MOCK",
                    idempotency_key=f"payout-{payment.id}",
                    payee_phone="+256700000088",
                    status=PayoutStatus.SUCCESS.value,
                )
            )
            await session.commit()

        # Admin already exists — verify-otp for existing phone
        session_factory2 = session_factory
        async with session_factory2() as session:
            session.add(
                OtpChallenge(
                    phone="+256700000001",
                    code_hash=hash_token("123456"),
                    expires_at=datetime.now(timezone.utc) + timedelta(minutes=10),
                )
            )
            await session.commit()

        r = await ac.post(
            "/api/v1/auth/verify-otp",
            json={"phone": "+256700000001", "code": "123456"},
        )
        assert r.status_code == 200, r.text
        headers = {"Authorization": f"Bearer {r.json()['access_token']}"}
        yield {"client": ac, "headers": headers}

    app.dependency_overrides.clear()
    await engine.dispose()


@pytest.mark.asyncio
async def test_admin_stats_includes_revenue_and_fees(env):
    client = env["client"]
    headers = env["headers"]
    r = await client.get("/api/v1/admin/stats", headers=headers)
    assert r.status_code == 200, r.text
    data = r.json()
    assert data["revenue_ugx"] == 10000.0
    assert data["platform_fee_ugx"] == 250.0
    assert data["payout_net_ugx"] == 9750.0
    assert data["successful_payouts"] == 1
    assert data["orders_by_status"].get("CONFIRMED") == 1
    assert data["payments_by_status"].get("SUCCESS") == 1


@pytest.mark.asyncio
async def test_admin_payouts_list_includes_fee(env):
    client = env["client"]
    headers = env["headers"]
    r = await client.get("/api/v1/admin/payouts", headers=headers)
    assert r.status_code == 200, r.text
    items = r.json()["items"]
    assert len(items) >= 1
    row = items[0]
    assert float(row["platform_fee"]) == 250.0
    assert float(row["amount"]) == 9750.0
    assert row["fee_bps"] == 250
