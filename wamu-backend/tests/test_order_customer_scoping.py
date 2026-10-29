"""Orders must belong to the authenticated buyer unless an explicit merchant receipt."""

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
            for phone in ("+256700000301", "+256700000302", "+256700000303"):
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
            owner = User(
                phone="+256700000301", phone_verified=True, role=UserRole.CUSTOMER.value
            )
            staff = User(
                phone="+256700000302", phone_verified=True, role=UserRole.CUSTOMER.value
            )
            buyer = User(
                phone="+256700000303", phone_verified=True, role=UserRole.CUSTOMER.value
            )
            session.add_all([owner, staff, buyer])
            await session.flush()
            session.add(UserProfile(user_id=owner.id, first_name="Owner", owns_business=True))
            session.add(UserProfile(user_id=staff.id, first_name="Staff"))
            session.add(UserProfile(user_id=buyer.id, first_name="Buyer"))
            biz = Business(
                owner_id=owner.id,
                name="Scoped Kitchen",
                slug=f"scoped-{uuid4().hex[:6]}",
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
                    user_id=owner.id,
                    role=MemberRole.OWNER.value,
                    is_active=True,
                )
            )
            session.add(
                BusinessMember(
                    business_id=biz.id,
                    user_id=staff.id,
                    role=MemberRole.STAFF.value,
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
                name="Rolex",
                slug=f"rolex-{uuid4().hex[:6]}",
                price=Decimal("8000"),
                currency="UGX",
                stock_quantity=50,
                is_active=True,
            )
            session.add(product)
            await session.commit()
            yield {
                "client": ac,
                "owner_phone": "+256700000301",
                "staff_phone": "+256700000302",
                "buyer_phone": "+256700000303",
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
async def test_shop_member_catalog_card_without_unit_price_stays_on_actor(env):
    """Shop owner posting a catalog order card (no unit_price) must not bill the chat peer.

    Mobile can fall into this path when merchant detection fails and the owner
    taps 'Send order card' instead of the receipt composer.
    """
    client = env["client"]
    owner_h = {"Authorization": f"Bearer {await _token(env, env['owner_phone'])}"}
    buyer_h = {"Authorization": f"Bearer {await _token(env, env['buyer_phone'])}"}

    convo = await client.post(
        "/api/v1/chat/conversations",
        headers=buyer_h,
        json={"business_id": env["business_id"]},
    )
    assert convo.status_code in (200, 201), convo.text
    convo_id = convo.json()["id"]

    created = await client.post(
        "/api/v1/orders",
        headers=owner_h,
        json={
            "business_id": env["business_id"],
            "conversation_id": convo_id,
            "fulfillment": "PICKUP",
            "items": [{"product_id": env["product_id"], "quantity": 1}],
        },
    )
    assert created.status_code == 201, created.text
    body = created.json()
    order_id = body["id"]

    me_owner = await client.get("/api/v1/users/me", headers=owner_h)
    assert body["customer_id"] == me_owner.json()["id"]

    owner_orders = await client.get("/api/v1/orders", headers=owner_h)
    assert any(o["id"] == order_id for o in owner_orders.json())

    buyer_orders = await client.get("/api/v1/orders", headers=buyer_h)
    assert all(o["id"] != order_id for o in buyer_orders.json())


@pytest.mark.asyncio
async def test_merchant_receipt_with_unit_price_still_bills_buyer(env):
    client = env["client"]
    owner_h = {"Authorization": f"Bearer {await _token(env, env['owner_phone'])}"}
    buyer_h = {"Authorization": f"Bearer {await _token(env, env['buyer_phone'])}"}

    convo = await client.post(
        "/api/v1/chat/conversations",
        headers=buyer_h,
        json={"business_id": env["business_id"]},
    )
    assert convo.status_code in (200, 201), convo.text
    convo_id = convo.json()["id"]

    receipt = await client.post(
        "/api/v1/orders",
        headers=owner_h,
        json={
            "business_id": env["business_id"],
            "conversation_id": convo_id,
            "fulfillment": "PICKUP",
            "items": [
                {
                    "product_id": env["product_id"],
                    "quantity": 1,
                    "unit_price": 7000,
                    "name": "Rolex (deal)",
                }
            ],
        },
    )
    assert receipt.status_code == 201, receipt.text
    body = receipt.json()
    order_id = body["id"]

    me_buyer = await client.get("/api/v1/users/me", headers=buyer_h)
    assert body["customer_id"] == me_buyer.json()["id"]

    buyer_orders = await client.get("/api/v1/orders", headers=buyer_h)
    assert any(o["id"] == order_id for o in buyer_orders.json())

    owner_orders = await client.get("/api/v1/orders", headers=owner_h)
    assert all(o["id"] != order_id for o in owner_orders.json())
