"""Merchant bargained receipt → buyer pays MoMo."""

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
    BusinessStatus,
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
            for phone in ("+256700000201", "+256700000202"):
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
            merchant = User(
                phone="+256700000201", phone_verified=True, role=UserRole.CUSTOMER.value
            )
            customer = User(
                phone="+256700000202", phone_verified=True, role=UserRole.CUSTOMER.value
            )
            session.add_all([merchant, customer])
            await session.flush()
            session.add(UserProfile(user_id=merchant.id, first_name="Shop", owns_business=True))
            session.add(UserProfile(user_id=customer.id, first_name="Buyer"))
            biz = Business(
                owner_id=merchant.id,
                name="Bargain Kitchen",
                slug=f"bargain-{uuid4().hex[:6]}",
                description="t",
                category_id=cat.id,
                status=BusinessStatus.ACTIVE.value,
                verification_status=VerificationStatus.VERIFIED.value,
            )
            session.add(biz)
            await session.flush()
            session.add(
                BusinessMember(
                    business_id=biz.id,
                    user_id=merchant.id,
                    role=MemberRole.OWNER.value,
                    is_active=True,
                )
            )
            session.add(
                Location(
                    business_id=biz.id,
                    address_line="Ntinda",
                    city="Kampala",
                    latitude=Decimal("0.35"),
                    longitude=Decimal("32.58"),
                )
            )
            product = Product(
                business_id=biz.id,
                category_id=cat.id,
                name="Matooke plate",
                slug=f"matooke-{uuid4().hex[:6]}",
                price=Decimal("30000"),
                currency="UGX",
                stock_quantity=20,
                is_active=True,
            )
            session.add(product)
            await session.commit()
            yield {
                "client": ac,
                "merchant_phone": "+256700000201",
                "customer_phone": "+256700000202",
                "business_id": str(biz.id),
                "product_id": str(product.id),
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
async def test_merchant_receipt_negotiated_price_buyer_pays(env):
    client = env["client"]
    m_h = {"Authorization": f"Bearer {await _token(env, env['merchant_phone'])}"}
    c_h = {"Authorization": f"Bearer {await _token(env, env['customer_phone'])}"}

    convo = await client.post(
        "/api/v1/chat/conversations",
        headers=c_h,
        json={"business_id": env["business_id"]},
    )
    assert convo.status_code in (200, 201), convo.text
    convo_id = convo.json()["id"]

    receipt = await client.post(
        "/api/v1/orders",
        headers=m_h,
        json={
            "business_id": env["business_id"],
            "conversation_id": convo_id,
            "fulfillment": "PICKUP",
            "customer_note": "Agreed 25k after bargain",
            "items": [
                {
                    "product_id": env["product_id"],
                    "quantity": 1,
                    "unit_price": 25000,
                    "name": "Matooke plate (bargained)",
                }
            ],
        },
    )
    assert receipt.status_code == 201, receipt.text
    body = receipt.json()
    assert float(body["total"]) == 25000
    assert float(body["items"][0]["unit_price"]) == 25000
    order_id = body["id"]
    # Customer on the order must be the buyer, not the merchant
    me_m = await client.get("/api/v1/users/me", headers=m_h)
    assert body["customer_id"] != me_m.json()["id"]

    # Buyer sees order; merchant is not the customer
    mine = await client.get("/api/v1/orders", headers=c_h)
    assert any(o["id"] == order_id for o in mine.json())

    revise = await client.patch(
        f"/api/v1/orders/{order_id}/receipt",
        headers=m_h,
        json={
            "items": [
                {
                    "product_id": env["product_id"],
                    "quantity": 1,
                    "unit_price": 24000,
                    "name": "Matooke plate (final)",
                }
            ],
            "fulfillment": "PICKUP",
            "delivery_fee": 0,
        },
    )
    assert revise.status_code == 200, revise.text
    assert float(revise.json()["total"]) == 24000

    pay = await client.post(
        "/api/v1/payments",
        headers=c_h,
        json={
            "order_id": order_id,
            "provider": "MTN",
            "idempotency_key": str(uuid4()),
            "phone": env["customer_phone"],
        },
    )
    assert pay.status_code in (200, 201), pay.text
    assert pay.json()["status"] in ("SUCCESS", "PENDING")
