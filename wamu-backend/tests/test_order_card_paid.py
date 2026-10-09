"""ORDER_CARD refresh + merchant ORDER_PAID notify after MoMo SUCCESS."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from decimal import Decimal
from uuid import uuid4

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
from app.models.chat import Conversation, ConversationMember, Message
from app.models.notification import Notification
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
            for phone in ("+256711100001", "+256711100002"):
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

            owner = User(phone="+256711100001", phone_verified=True, role=UserRole.BUSINESS.value)
            session.add(owner)
            await session.flush()
            session.add(UserProfile(user_id=owner.id, first_name="Owner", last_name="Biz"))

            customer = User(
                phone="+256711100002", phone_verified=True, role=UserRole.CUSTOMER.value
            )
            session.add(customer)
            await session.flush()
            session.add(UserProfile(user_id=customer.id, first_name="Cust", last_name="Omer"))

            biz = Business(
                owner_id=owner.id,
                name="Card Kitchen",
                slug=f"card-{uuid4().hex[:6]}",
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
                name="Meal",
                slug=f"meal-{uuid4().hex[:6]}",
                price=Decimal("10000"),
                currency="UGX",
                stock_quantity=5,
            )
            session.add(product)
            await session.flush()

            convo = Conversation(type="CUSTOMER_BUSINESS", business_id=biz.id)
            session.add(convo)
            await session.flush()
            session.add(ConversationMember(conversation_id=convo.id, user_id=owner.id))
            session.add(ConversationMember(conversation_id=convo.id, user_id=customer.id))

            await session.commit()
            ids = {
                "biz_id": str(biz.id),
                "product_id": str(product.id),
                "convo_id": str(convo.id),
                "owner_id": str(owner.id),
            }

        cust = await ac.post(
            "/api/v1/auth/verify-otp",
            json={"phone": "+256711100002", "code": "123456"},
        )
        own = await ac.post(
            "/api/v1/auth/verify-otp",
            json={"phone": "+256711100001", "code": "123456"},
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


@pytest.mark.asyncio
async def test_order_card_paid_and_merchant_notified(env):
    client = env["client"]
    ch = env["customer_headers"]

    order = await client.post(
        "/api/v1/orders",
        headers=ch,
        json={
            "business_id": env["biz_id"],
            "conversation_id": env["convo_id"],
            "fulfillment": "DELIVERY",
            "delivery_address": "Nakawa Trading Centre, Kampala",
            "items": [{"product_id": env["product_id"], "quantity": 1}],
        },
    )
    assert order.status_code == 201, order.text
    order_id = order.json()["id"]

    # Card created unpaid — stock not yet committed
    async with env["session_factory"]() as session:
        msg = await session.scalar(
            select(Message).where(Message.client_message_id == f"order-card-{order_id}")
        )
        assert msg is not None
        assert '"payment_status": "UNPAID"' in msg.body or '"payment_status":"UNPAID"' in msg.body
        product = await session.get(Product, __import__("uuid").UUID(env["product_id"]))
        assert product is not None and product.stock_quantity == 5

    pay = await client.post(
        "/api/v1/payments",
        headers=ch,
        json={
            "order_id": order_id,
            "provider": "MTN",
            "idempotency_key": f"card-pay-{uuid4().hex[:12]}",
            "phone": "+256711100002",
        },
    )
    assert pay.status_code == 201, pay.text
    assert pay.json()["status"] == "SUCCESS"

    async with env["session_factory"]() as session:
        msg = await session.scalar(
            select(Message).where(Message.client_message_id == f"order-card-{order_id}")
        )
        assert msg is not None
        assert "SUCCESS" in msg.body
        assert "Paid" in msg.body or "CONFIRMED" in msg.body

        product = await session.get(Product, __import__("uuid").UUID(env["product_id"]))
        assert product is not None and product.stock_quantity == 4

        note = await session.scalar(
            select(Notification).where(
                Notification.user_id == __import__("uuid").UUID(env["owner_id"]),
                Notification.type == "ORDER_PAID",
            )
        )
        assert note is not None
        assert "paid" in (note.title or "").lower() or "fulfill" in (note.body or "").lower()
        assert note.data is not None
        assert note.data.get("conversation_id") == env["convo_id"]
        assert note.data.get("order_id") == order_id
