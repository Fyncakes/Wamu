"""Stock commits on payment SUCCESS; restocks when a paid order is cancelled."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from decimal import Decimal
from uuid import UUID, uuid4

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
from app.models.product import Product
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
            for phone in ("+256722200001", "+256722200002"):
                session.add(
                    OtpChallenge(
                        phone=phone,
                        code_hash=hash_token("123456"),
                        expires_at=datetime.now(timezone.utc) + timedelta(minutes=10),
                    )
                )
            cat = Category(name="Food", slug=f"stock-{uuid4().hex[:6]}", description="t")
            session.add(cat)
            await session.flush()

            owner = User(phone="+256722200001", phone_verified=True, role=UserRole.BUSINESS.value)
            session.add(owner)
            await session.flush()
            session.add(UserProfile(user_id=owner.id, first_name="Owner", last_name="Stock"))

            customer = User(
                phone="+256722200002", phone_verified=True, role=UserRole.CUSTOMER.value
            )
            session.add(customer)
            await session.flush()
            session.add(UserProfile(user_id=customer.id, first_name="Cust", last_name="Stock"))

            biz = Business(
                owner_id=owner.id,
                name="Stock Kitchen",
                slug=f"stock-{uuid4().hex[:6]}",
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
                    latitude=Decimal("0.3476"),
                    longitude=Decimal("32.63"),
                )
            )
            product = Product(
                business_id=biz.id,
                category_id=cat.id,
                name="Stock Meal",
                slug=f"meal-{uuid4().hex[:6]}",
                price=Decimal("8000"),
                currency="UGX",
                stock_quantity=10,
            )
            session.add(product)
            await session.commit()
            ids = {
                "biz_id": str(biz.id),
                "product_id": str(product.id),
            }

        cust = await ac.post(
            "/api/v1/auth/verify-otp",
            json={"phone": "+256722200002", "code": "123456"},
        )
        own = await ac.post(
            "/api/v1/auth/verify-otp",
            json={"phone": "+256722200001", "code": "123456"},
        )
        assert cust.status_code == 200 and own.status_code == 200
        yield {
            "client": ac,
            "session_factory": session_factory,
            "customer_headers": {"Authorization": f"Bearer {cust.json()['access_token']}"},
            "owner_headers": {"Authorization": f"Bearer {own.json()['access_token']}"},
            **ids,
        }

    app.dependency_overrides.clear()
    await engine.dispose()


async def _stock(session_factory, product_id: str) -> int:
    async with session_factory() as session:
        product = await session.get(Product, UUID(product_id))
        assert product is not None and product.stock_quantity is not None
        return product.stock_quantity


@pytest.mark.asyncio
async def test_stock_unchanged_until_pay_then_restock_on_cancel(env):
    client = env["client"]
    ch = env["customer_headers"]
    oh = env["owner_headers"]
    pid = env["product_id"]

    assert await _stock(env["session_factory"], pid) == 10

    order = await client.post(
        "/api/v1/orders",
        headers=ch,
        json={
            "business_id": env["biz_id"],
            "fulfillment": "PICKUP",
            "items": [{"product_id": pid, "quantity": 3}],
        },
    )
    assert order.status_code == 201, order.text
    order_id = order.json()["id"]
    assert await _stock(env["session_factory"], pid) == 10

    # Unpaid cancel must not change stock
    cancel_pending = await client.patch(
        f"/api/v1/orders/{order_id}/status",
        headers=ch,
        json={"status": "CANCELLED"},
    )
    assert cancel_pending.status_code == 200, cancel_pending.text
    assert await _stock(env["session_factory"], pid) == 10

    order2 = await client.post(
        "/api/v1/orders",
        headers=ch,
        json={
            "business_id": env["biz_id"],
            "fulfillment": "PICKUP",
            "items": [{"product_id": pid, "quantity": 3}],
        },
    )
    assert order2.status_code == 201, order2.text
    order2_id = order2.json()["id"]
    assert await _stock(env["session_factory"], pid) == 10

    pay = await client.post(
        "/api/v1/payments",
        headers=ch,
        json={
            "order_id": order2_id,
            "provider": "MTN",
            "idempotency_key": f"stock-pay-{uuid4().hex[:12]}",
            "phone": "+256722200002",
        },
    )
    assert pay.status_code == 201, pay.text
    assert pay.json()["status"] == "SUCCESS"
    assert await _stock(env["session_factory"], pid) == 7

    # Merchant cancel after pay restores stock
    cancel_paid = await client.patch(
        f"/api/v1/orders/{order2_id}/status",
        headers=oh,
        json={"status": "CANCELLED"},
    )
    assert cancel_paid.status_code == 200, cancel_paid.text
    assert await _stock(env["session_factory"], pid) == 10

    pay_check = await client.get(f"/api/v1/payments/{pay.json()['id']}", headers=ch)
    assert pay_check.status_code == 200, pay_check.text
    assert pay_check.json()["status"] == "REFUNDED"
