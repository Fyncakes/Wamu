"""SYSTEM status lines + ORDER_CARD delivery_status sync in merchant chat."""

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
from app.models.chat import Conversation, ConversationMember, Message
from app.models.product import Product
from app.models.rider import Delivery, RiderProfile, RiderStatus
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
            cat = Category(name="Food", slug=f"chat-{uuid4().hex[:6]}", description="t")
            session.add(cat)
            await session.flush()

            owner = User(phone="+256733300001", phone_verified=True, role=UserRole.BUSINESS.value)
            session.add(owner)
            await session.flush()
            session.add(UserProfile(user_id=owner.id, first_name="Owner", last_name="Chat"))

            customer = User(
                phone="+256733300002", phone_verified=True, role=UserRole.CUSTOMER.value
            )
            session.add(customer)
            await session.flush()
            session.add(UserProfile(user_id=customer.id, first_name="Cust", last_name="Chat"))

            rider_user = User(
                phone="+256733300003", phone_verified=True, role=UserRole.CUSTOMER.value
            )
            session.add(rider_user)
            await session.flush()
            session.add(UserProfile(user_id=rider_user.id, first_name="Rider", last_name="Chat"))
            rider = RiderProfile(
                user_id=rider_user.id,
                display_name="Chat Rider",
                vehicle_type="BODA",
                status=RiderStatus.APPROVED.value,
                available_delivery=True,
                wamu_rider_ref=f"WR-{uuid4().hex[:8].upper()}",
            )
            session.add(rider)

            biz = Business(
                owner_id=owner.id,
                name="Chat Kitchen",
                slug=f"chat-{uuid4().hex[:6]}",
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
                name="Chat Meal",
                slug=f"meal-{uuid4().hex[:6]}",
                price=Decimal("9000"),
                currency="UGX",
                stock_quantity=8,
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
            }

        tokens = {}
        for phone, key in (
            ("+256733300002", "customer"),
            ("+256733300001", "owner"),
            ("+256733300003", "rider"),
        ):
            r = await ac.post(
                "/api/v1/auth/verify-otp",
                json={"phone": phone, "code": "123456"},
            )
            assert r.status_code == 200, r.text
            tokens[key] = {"Authorization": f"Bearer {r.json()['access_token']}"}

        yield {
            "client": ac,
            "session_factory": session_factory,
            "customer_headers": tokens["customer"],
            "owner_headers": tokens["owner"],
            "rider_headers": tokens["rider"],
            **ids,
        }

    app.dependency_overrides.clear()
    await engine.dispose()


@pytest.mark.asyncio
async def test_delivery_status_posts_system_messages_in_chat(env):
    client = env["client"]
    ch = env["customer_headers"]
    rh = env["rider_headers"]
    oh = env["owner_headers"]

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

    pay = await client.post(
        "/api/v1/payments",
        headers=ch,
        json={
            "order_id": order_id,
            "provider": "MTN",
            "idempotency_key": f"chat-pay-{uuid4().hex[:12]}",
            "phone": "+256733300002",
        },
    )
    assert pay.status_code == 201, pay.text
    assert pay.json()["status"] == "SUCCESS"

    async with env["session_factory"]() as session:
        assigned = await session.scalar(
            select(Message).where(
                Message.conversation_id == UUID(env["convo_id"]),
                Message.message_type == "SYSTEM",
                Message.body.contains("Rider assigned"),
            )
        )
        assert assigned is not None

        delivery = await session.scalar(select(Delivery).where(Delivery.order_id == UUID(order_id)))
        assert delivery is not None
        delivery_id = str(delivery.id)

    # Advance a couple of rider steps — each posts SYSTEM + refreshes card
    for status in ("GOING_TO_PICKUP", "AT_PICKUP", "PICKED_UP", "IN_TRANSIT"):
        adv = await client.patch(
            f"/api/v1/deliveries/{delivery_id}",
            headers=rh,
            json={"status": status},
        )
        assert adv.status_code == 200, adv.text

    done = await client.patch(
        f"/api/v1/deliveries/{delivery_id}",
        headers=rh,
        json={"status": "DELIVERED", "proof_note": "Handed at gate"},
    )
    assert done.status_code == 200, done.text

    async with env["session_factory"]() as session:
        systems = (
            await session.execute(
                select(Message).where(
                    Message.conversation_id == UUID(env["convo_id"]),
                    Message.message_type == "SYSTEM",
                )
            )
        ).scalars().all()
        bodies = " | ".join(m.body for m in systems)
        assert "on the way" in bodies.lower() or "IN_TRANSIT" in bodies or "way to you" in bodies
        assert "Delivered" in bodies or "enjoy" in bodies.lower()

        card = await session.scalar(
            select(Message).where(Message.client_message_id == f"order-card-{order_id}")
        )
        assert card is not None
        assert "DELIVERED" in card.body
        assert "delivery_status" in card.body

    # Merchant fulfill path also posts (use a fresh unpaid→paid pickup with status advance)
    order2 = await client.post(
        "/api/v1/orders",
        headers=ch,
        json={
            "business_id": env["biz_id"],
            "conversation_id": env["convo_id"],
            "fulfillment": "PICKUP",
            "items": [{"product_id": env["product_id"], "quantity": 1}],
        },
    )
    assert order2.status_code == 201, order2.text
    oid2 = order2.json()["id"]
    pay2 = await client.post(
        "/api/v1/payments",
        headers=ch,
        json={
            "order_id": oid2,
            "provider": "MTN",
            "idempotency_key": f"chat-pay2-{uuid4().hex[:12]}",
            "phone": "+256733300002",
        },
    )
    assert pay2.status_code == 201, pay2.text

    # Get version from order
    detail = await client.get(f"/api/v1/orders/{oid2}", headers=oh)
    assert detail.status_code == 200
    ver = detail.json().get("version")
    proc = await client.patch(
        f"/api/v1/orders/{oid2}/status",
        headers=oh,
        json={"status": "PROCESSING", "version": ver},
    )
    assert proc.status_code == 200, proc.text

    async with env["session_factory"]() as session:
        prep = await session.scalar(
            select(Message).where(
                Message.conversation_id == UUID(env["convo_id"]),
                Message.message_type == "SYSTEM",
                Message.body.contains("preparing"),
            )
        )
        assert prep is not None
