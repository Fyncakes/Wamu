"""
WAMU-011 — payment idempotency + chat WS ticket membership tests.
"""

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
            session.add(
                OtpChallenge(
                    phone="+256700000088",
                    code_hash=hash_token("123456"),
                    expires_at=datetime.now(timezone.utc) + timedelta(minutes=10),
                )
            )
            cat = Category(name="Test", slug=f"test-{uuid4().hex[:6]}", description="t")
            session.add(cat)
            await session.flush()

            owner = User(
                phone="+256700000077",
                phone_verified=True,
                role=UserRole.BUSINESS.value,
            )
            session.add(owner)
            await session.flush()
            session.add(UserProfile(user_id=owner.id, first_name="Owner", last_name="Biz"))

            biz = Business(
                owner_id=owner.id,
                name="Test Bakery",
                slug=f"test-bakery-{uuid4().hex[:6]}",
                category_id=cat.id,
                status=BusinessStatus.ACTIVE.value,
                verification_status=VerificationStatus.VERIFIED.value,
            )
            session.add(biz)
            await session.flush()

            product = Product(
                business_id=biz.id,
                name="Cake",
                slug=f"cake-{uuid4().hex[:6]}",
                price=Decimal("25000.00"),
                currency="UGX",
                stock_quantity=10,
                is_active=True,
            )
            session.add(product)
            await session.commit()

            product_id = str(product.id)
            business_id = str(biz.id)

        # login customer
        r = await ac.post(
            "/api/v1/auth/verify-otp",
            json={"phone": "+256700000088", "code": "123456"},
        )
        assert r.status_code == 200, r.text
        token = r.json()["access_token"]
        headers = {"Authorization": f"Bearer {token}"}

        yield {
            "client": ac,
            "headers": headers,
            "product_id": product_id,
            "business_id": business_id,
            "session_factory": session_factory,
        }

    app.dependency_overrides.clear()
    await engine.dispose()


@pytest.mark.asyncio
async def test_request_id_header(env):
    r = await env["client"].get("/api/v1/health")
    assert r.status_code == 200
    assert r.headers.get("X-Request-ID")


@pytest.mark.asyncio
async def test_payment_idempotency_returns_same_payment(env):
    client = env["client"]
    headers = env["headers"]

    order = await client.post(
        "/api/v1/orders",
        headers=headers,
        json={
            "business_id": env["business_id"],
            "items": [{"product_id": env["product_id"], "quantity": 1}],
            "fulfillment": "PICKUP",
        },
    )
    assert order.status_code == 201, order.text
    order_id = order.json()["id"]
    key = f"idem-{uuid4().hex}"

    p1 = await client.post(
        "/api/v1/payments",
        headers=headers,
        json={
            "order_id": order_id,
            "provider": "MOCK",
            "phone": "+256700000088",
            "idempotency_key": key,
        },
    )
    assert p1.status_code == 201, p1.text
    p2 = await client.post(
        "/api/v1/payments",
        headers=headers,
        json={
            "order_id": order_id,
            "provider": "MOCK",
            "phone": "+256700000088",
            "idempotency_key": key,
        },
    )
    assert p2.status_code == 201, p2.text
    assert p1.json()["id"] == p2.json()["id"]
    assert p1.json()["status"] == p2.json()["status"]


@pytest.mark.asyncio
async def test_payment_idempotency_rejects_different_order(env):
    client = env["client"]
    headers = env["headers"]
    key = f"idem-conflict-{uuid4().hex}"

    async def _order():
        r = await client.post(
            "/api/v1/orders",
            headers=headers,
            json={
                "business_id": env["business_id"],
                "items": [{"product_id": env["product_id"], "quantity": 1}],
                "fulfillment": "PICKUP",
            },
        )
        assert r.status_code == 201, r.text
        return r.json()["id"]

    o1 = await _order()
    o2 = await _order()

    p1 = await client.post(
        "/api/v1/payments",
        headers=headers,
        json={
            "order_id": o1,
            "provider": "MOCK",
            "phone": "+256700000088",
            "idempotency_key": key,
        },
    )
    assert p1.status_code == 201, p1.text

    p2 = await client.post(
        "/api/v1/payments",
        headers=headers,
        json={
            "order_id": o2,
            "provider": "MOCK",
            "phone": "+256700000088",
            "idempotency_key": key,
        },
    )
    assert p2.status_code == 409, p2.text


@pytest.mark.asyncio
async def test_order_includes_payment_status_fields(env):
    client = env["client"]
    headers = env["headers"]

    unpaid = await client.post(
        "/api/v1/orders",
        headers=headers,
        json={
            "business_id": env["business_id"],
            "items": [{"product_id": env["product_id"], "quantity": 1}],
            "fulfillment": "PICKUP",
        },
    )
    assert unpaid.status_code == 201, unpaid.text
    unpaid_body = unpaid.json()
    assert unpaid_body.get("payment_status") is None
    assert unpaid_body.get("payment_provider") is None

    order_id = unpaid_body["id"]
    pay = await client.post(
        "/api/v1/payments",
        headers=headers,
        json={
            "order_id": order_id,
            "provider": "MOCK",
            "phone": "+256700000088",
            "idempotency_key": f"pay-status-{uuid4().hex}",
        },
    )
    assert pay.status_code == 201, pay.text
    pay_status = pay.json()["status"]
    pay_provider = pay.json()["provider"]

    detail = await client.get(f"/api/v1/orders/{order_id}", headers=headers)
    assert detail.status_code == 200, detail.text
    assert detail.json()["payment_status"] == pay_status
    assert detail.json()["payment_provider"] == pay_provider

    listing = await client.get("/api/v1/orders", headers=headers)
    assert listing.status_code == 200, listing.text
    match = next(o for o in listing.json() if o["id"] == order_id)
    assert match["payment_status"] == pay_status
    assert match["payment_provider"] == pay_provider


@pytest.mark.asyncio
async def test_ws_ticket_requires_membership(env):
    client = env["client"]
    headers = env["headers"]
    # Random conversation — user is not a member
    fake_convo = str(uuid4())
    r = await client.post(
        "/api/v1/chat/ws-ticket",
        headers=headers,
        json={"conversation_id": fake_convo},
    )
    assert r.status_code in {403, 404}


@pytest.mark.asyncio
async def test_ws_ticket_for_own_dm(env):
    client = env["client"]
    headers = env["headers"]
    # Start DM with seeded owner phone
    convo = await client.post(
        "/api/v1/chat/conversations",
        headers=headers,
        json={"peer_phone": "+256700000077", "initial_message": "hi"},
    )
    assert convo.status_code == 201, convo.text
    cid = convo.json()["id"]
    ticket = await client.post(
        "/api/v1/chat/ws-ticket",
        headers=headers,
        json={"conversation_id": cid},
    )
    assert ticket.status_code == 200, ticket.text
    assert ticket.json()["ticket"]
    assert ticket.json()["conversation_id"] == cid
