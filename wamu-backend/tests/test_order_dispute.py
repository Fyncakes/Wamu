"""Order dispute open + admin resolve (refund / reject)."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from decimal import Decimal
from uuid import UUID, uuid4

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select
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
from app.models.notification import Notification
from app.models.order import Order, OrderItem, OrderStatus
from app.models.payment import Payment, PaymentStatus
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
            for phone in ("+256711200001", "+256711200002", "+256711200003"):
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
                phone="+256711200001", phone_verified=True, role=UserRole.ADMIN.value
            )
            owner = User(
                phone="+256711200002", phone_verified=True, role=UserRole.BUSINESS.value
            )
            customer = User(
                phone="+256711200003", phone_verified=True, role=UserRole.CUSTOMER.value
            )
            session.add_all([admin, owner, customer])
            await session.flush()
            session.add(UserProfile(user_id=admin.id, first_name="Admin"))
            session.add(UserProfile(user_id=owner.id, first_name="Owner", last_name="Biz"))
            session.add(UserProfile(user_id=customer.id, first_name="Cust", last_name="Omer"))

            biz = Business(
                owner_id=owner.id,
                name="Dispute Kitchen",
                slug=f"disp-{uuid4().hex[:6]}",
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
                name="Plate",
                slug=f"plate-{uuid4().hex[:6]}",
                price=Decimal("12000"),
                currency="UGX",
                stock_quantity=5,
            )
            session.add(product)
            await session.flush()

            order = Order(
                customer_id=customer.id,
                business_id=biz.id,
                status=OrderStatus.DELIVERED.value,
                fulfillment="DELIVERY",
                delivery_address="Nakawa",
                subtotal=Decimal("12000"),
                delivery_fee=Decimal("3000"),
                total=Decimal("15000"),
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
                    amount=Decimal("15000"),
                    currency="UGX",
                    provider="MOCK",
                    provider_reference=f"MOCK-{uuid4().hex[:8]}",
                    idempotency_key=f"idem-{uuid4().hex}",
                    status=PaymentStatus.SUCCESS.value,
                    phone=customer.phone,
                )
            )
            await session.commit()
            order_id = str(order.id)
            owner_id = str(owner.id)

        yield {
            "client": ac,
            "admin_phone": "+256711200001",
            "owner_phone": "+256711200002",
            "customer_phone": "+256711200003",
            "order_id": order_id,
            "owner_id": owner_id,
            "session_factory": session_factory,
        }

    app.dependency_overrides.clear()
    await engine.dispose()


async def _token(client: AsyncClient, phone: str) -> str:
    r = await client.post("/api/v1/auth/verify-otp", json={"phone": phone, "code": "123456"})
    assert r.status_code == 200, r.text
    return r.json()["access_token"]


async def _token_fresh(env, phone: str) -> str:
    """Insert a fresh OTP then verify."""
    client: AsyncClient = env["client"]
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
    return await _token(client, phone)


@pytest.mark.asyncio
async def test_open_dispute_and_admin_refund(env):
    client: AsyncClient = env["client"]
    cust_tok = await _token_fresh(env, env["customer_phone"])
    cust_h = {"Authorization": f"Bearer {cust_tok}"}

    open_r = await client.post(
        "/api/v1/disputes",
        headers=cust_h,
        json={
            "order_id": env["order_id"],
            "reason": "WRONG_ITEMS",
            "description": "Got chicken instead of fish",
        },
    )
    assert open_r.status_code == 201, open_r.text
    dispute = open_r.json()
    assert dispute["status"] == "OPEN"
    assert dispute["reason"] == "WRONG_ITEMS"
    dispute_id = dispute["id"]

    sf = env["session_factory"]
    async with sf() as session:
        notif = await session.scalar(
            select(Notification).where(
                Notification.user_id == UUID(env["owner_id"]),
                Notification.type == "ORDER_DISPUTE",
            )
        )
        assert notif is not None

    dup = await client.post(
        "/api/v1/disputes",
        headers=cust_h,
        json={"order_id": env["order_id"], "reason": "QUALITY"},
    )
    assert dup.status_code == 409, dup.text

    admin_tok = await _token_fresh(env, env["admin_phone"])
    admin_h = {"Authorization": f"Bearer {admin_tok}"}

    listed = await client.get("/api/v1/admin/disputes", headers=admin_h)
    assert listed.status_code == 200, listed.text
    items = listed.json()
    if isinstance(items, dict):
        items = items.get("items", [])
    assert any(d["id"] == dispute_id for d in items)

    owner_tok = await _token_fresh(env, env["owner_phone"])
    biz_list = await client.get(
        "/api/v1/disputes/business",
        headers={"Authorization": f"Bearer {owner_tok}"},
    )
    assert biz_list.status_code == 200, biz_list.text
    assert any(d["id"] == dispute_id for d in biz_list.json())

    resolve = await client.post(
        f"/api/v1/admin/disputes/{dispute_id}/resolve",
        headers=admin_h,
        json={"status": "RESOLVED_REFUND", "resolution_note": "Approved"},
    )
    assert resolve.status_code == 200, resolve.text
    assert resolve.json()["status"] == "RESOLVED_REFUND"

    async with sf() as session:
        order = await session.get(Order, UUID(env["order_id"]))
        assert order is not None
        assert order.status == OrderStatus.REFUNDED.value
        payment = await session.scalar(
            select(Payment).where(Payment.order_id == order.id)
        )
        assert payment is not None
        assert payment.status == PaymentStatus.REFUNDED.value
        cust_notif = await session.scalar(
            select(Notification).where(
                Notification.type == "ORDER_DISPUTE",
                Notification.title == "Dispute update",
            )
        )
        assert cust_notif is not None


@pytest.mark.asyncio
async def test_dispute_rejects_unpaid_or_pending_order(env):
    client: AsyncClient = env["client"]
    sf = env["session_factory"]

    async with sf() as session:
        order = await session.get(Order, UUID(env["order_id"]))
        assert order is not None
        order.status = OrderStatus.CONFIRMED.value
        await session.commit()

    cust_tok = await _token_fresh(env, env["customer_phone"])
    r = await client.post(
        "/api/v1/disputes",
        headers={"Authorization": f"Bearer {cust_tok}"},
        json={"order_id": env["order_id"], "reason": "OTHER"},
    )
    assert r.status_code == 400, r.text
