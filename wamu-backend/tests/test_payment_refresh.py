"""Client payment refresh: PENDING/PROCESSING → SUCCESS via provider check_status."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from decimal import Decimal
from unittest.mock import patch
from uuid import uuid4

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.config import get_settings
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
            for phone in ("+256744400001", "+256744400002"):
                session.add(
                    OtpChallenge(
                        phone=phone,
                        code_hash=hash_token("123456"),
                        expires_at=datetime.now(timezone.utc) + timedelta(minutes=10),
                    )
                )
            cat = Category(name="Food", slug=f"pay-{uuid4().hex[:6]}", description="t")
            session.add(cat)
            await session.flush()
            owner = User(phone="+256744400001", phone_verified=True, role=UserRole.BUSINESS.value)
            session.add(owner)
            await session.flush()
            session.add(UserProfile(user_id=owner.id, first_name="O", last_name="P"))
            customer = User(
                phone="+256744400002", phone_verified=True, role=UserRole.CUSTOMER.value
            )
            session.add(customer)
            await session.flush()
            session.add(UserProfile(user_id=customer.id, first_name="C", last_name="P"))
            biz = Business(
                owner_id=owner.id,
                name="Pay Kitchen",
                slug=f"pay-{uuid4().hex[:6]}",
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
                name="Pay Meal",
                slug=f"meal-{uuid4().hex[:6]}",
                price=Decimal("5000"),
                currency="UGX",
                stock_quantity=4,
            )
            session.add(product)
            await session.commit()
            ids = {"biz_id": str(biz.id), "product_id": str(product.id)}

        cust = await ac.post(
            "/api/v1/auth/verify-otp",
            json={"phone": "+256744400002", "code": "123456"},
        )
        assert cust.status_code == 200
        yield {
            "client": ac,
            "customer_headers": {"Authorization": f"Bearer {cust.json()['access_token']}"},
            **ids,
        }

    app.dependency_overrides.clear()
    await engine.dispose()


@pytest.mark.asyncio
async def test_refresh_promotes_pending_payment_to_success(env):
    client = env["client"]
    ch = env["customer_headers"]
    settings = get_settings()

    order = await client.post(
        "/api/v1/orders",
        headers=ch,
        json={
            "business_id": env["biz_id"],
            "fulfillment": "PICKUP",
            "items": [{"product_id": env["product_id"], "quantity": 1}],
        },
    )
    assert order.status_code == 201, order.text
    order_id = order.json()["id"]

    with patch.object(settings, "payment_mock_auto_success", False):
        pay = await client.post(
            "/api/v1/payments",
            headers=ch,
            json={
                "order_id": order_id,
                "provider": "MOCK",
                "idempotency_key": f"refresh-{uuid4().hex[:12]}",
                "phone": "+256744400002",
            },
        )
    assert pay.status_code == 201, pay.text
    body = pay.json()
    assert body["status"] in {"PENDING", "PROCESSING"}
    payment_id = body["id"]

    # Mock check_status returns SUCCESS → refresh finalizes (stock, confirm, etc.).
    refreshed = await client.post(
        f"/api/v1/payments/{payment_id}/refresh",
        headers=ch,
    )
    assert refreshed.status_code == 200, refreshed.text
    assert refreshed.json()["status"] == "SUCCESS"

    # Idempotent second refresh
    again = await client.post(f"/api/v1/payments/{payment_id}/refresh", headers=ch)
    assert again.status_code == 200
    assert again.json()["status"] == "SUCCESS"

    detail = await client.get(f"/api/v1/orders/{order_id}", headers=ch)
    assert detail.status_code == 200
    assert detail.json()["status"] == "CONFIRMED"
