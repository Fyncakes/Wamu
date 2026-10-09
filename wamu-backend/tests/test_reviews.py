"""Order-linked reviews — only DELIVERED orders; owner can reply."""

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
    MemberRole,
    VerificationStatus,
)
from app.models.order import Order, OrderItem, OrderStatus
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
            for phone in ("+256700000088", "+256700000077"):
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
                phone="+256700000077",
                phone_verified=True,
                role=UserRole.BUSINESS.value,
            )
            session.add(owner)
            await session.flush()
            session.add(UserProfile(user_id=owner.id, first_name="Owner", last_name="Biz"))

            customer = User(
                phone="+256700000088",
                phone_verified=True,
                role=UserRole.CUSTOMER.value,
            )
            session.add(customer)
            await session.flush()
            session.add(UserProfile(user_id=customer.id, first_name="Cust", last_name="Omer"))

            biz = Business(
                owner_id=owner.id,
                name="Review Grill",
                slug=f"review-{uuid4().hex[:6]}",
                category_id=cat.id,
                phone="+256700000077",
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
                )
            )

            product = Product(
                business_id=biz.id,
                name="Chapati",
                slug=f"chapati-{uuid4().hex[:6]}",
                price=Decimal("3000.00"),
                currency="UGX",
                stock_quantity=10,
                is_active=True,
            )
            session.add(product)
            await session.flush()

            pending = Order(
                customer_id=customer.id,
                business_id=biz.id,
                status=OrderStatus.PENDING.value,
                subtotal=Decimal("3000.00"),
                delivery_fee=Decimal("0.00"),
                total=Decimal("3000.00"),
                currency="UGX",
                fulfillment="PICKUP",
            )
            session.add(pending)
            await session.flush()
            session.add(
                OrderItem(
                    order_id=pending.id,
                    product_id=product.id,
                    product_name="Chapati",
                    quantity=1,
                    unit_price=Decimal("3000.00"),
                    subtotal=Decimal("3000.00"),
                )
            )

            delivered = Order(
                customer_id=customer.id,
                business_id=biz.id,
                status=OrderStatus.DELIVERED.value,
                subtotal=Decimal("3000.00"),
                delivery_fee=Decimal("0.00"),
                total=Decimal("3000.00"),
                currency="UGX",
                fulfillment="PICKUP",
            )
            session.add(delivered)
            await session.flush()
            session.add(
                OrderItem(
                    order_id=delivered.id,
                    product_id=product.id,
                    product_name="Chapati",
                    quantity=1,
                    unit_price=Decimal("3000.00"),
                    subtotal=Decimal("3000.00"),
                )
            )
            await session.commit()

            pending_id = str(pending.id)
            delivered_id = str(delivered.id)
            business_id = str(biz.id)

        cust = await ac.post(
            "/api/v1/auth/verify-otp",
            json={"phone": "+256700000088", "code": "123456"},
        )
        assert cust.status_code == 200, cust.text
        own = await ac.post(
            "/api/v1/auth/verify-otp",
            json={"phone": "+256700000077", "code": "123456"},
        )
        assert own.status_code == 200, own.text

        yield {
            "client": ac,
            "customer_headers": {"Authorization": f"Bearer {cust.json()['access_token']}"},
            "owner_headers": {"Authorization": f"Bearer {own.json()['access_token']}"},
            "business_id": business_id,
            "pending_order_id": pending_id,
            "delivered_order_id": delivered_id,
        }

    app.dependency_overrides.clear()
    await engine.dispose()


@pytest.mark.asyncio
async def test_review_requires_delivered_order(env):
    client = env["client"]
    headers = env["customer_headers"]
    biz = env["business_id"]

    bad = await client.post(
        "/api/v1/reviews",
        headers=headers,
        json={
            "business_id": biz,
            "order_id": env["pending_order_id"],
            "rating": 5,
            "comment": "too early",
        },
    )
    assert bad.status_code == 400, bad.text
    assert "delivered" in bad.json()["detail"].lower()


@pytest.mark.asyncio
async def test_review_happy_path_and_owner_reply(env):
    client = env["client"]
    headers = env["customer_headers"]
    owner = env["owner_headers"]
    biz = env["business_id"]

    created = await client.post(
        "/api/v1/reviews",
        headers=headers,
        json={
            "business_id": biz,
            "order_id": env["delivered_order_id"],
            "rating": 4,
            "comment": "Fresh chapati",
        },
    )
    assert created.status_code == 201, created.text
    body = created.json()
    assert body["rating"] == 4
    assert body["order_id"] == env["delivered_order_id"]
    assert body["reply"] is None
    review_id = body["id"]

    listed = await client.get(f"/api/v1/reviews/business/{biz}")
    assert listed.status_code == 200
    assert any(r["id"] == review_id for r in listed.json())

    reply = await client.post(
        f"/api/v1/reviews/{review_id}/reply",
        headers=owner,
        json={"reply": "Webale nnyo!"},
    )
    assert reply.status_code == 200, reply.text
    assert reply.json()["reply"] == "Webale nnyo!"

    listed2 = await client.get(f"/api/v1/reviews/business/{biz}")
    match = next(r for r in listed2.json() if r["id"] == review_id)
    assert match["reply"] == "Webale nnyo!"


@pytest.mark.asyncio
async def test_review_rejects_foreign_order(env):
    client = env["client"]
    # Owner tries to review using customer's delivered order
    bad = await client.post(
        "/api/v1/reviews",
        headers=env["owner_headers"],
        json={
            "business_id": env["business_id"],
            "order_id": env["delivered_order_id"],
            "rating": 5,
        },
    )
    assert bad.status_code == 403, bad.text
