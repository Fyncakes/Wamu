"""Owners can re-edit product name, price, stock, and status after creating."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from decimal import Decimal
from uuid import uuid4

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
            session.add(
                OtpChallenge(
                    phone="+256733300001",
                    code_hash=hash_token("123456"),
                    expires_at=datetime.now(timezone.utc) + timedelta(minutes=10),
                )
            )
            cat = Category(name="Food", slug=f"edit-{uuid4().hex[:6]}", description="t")
            session.add(cat)
            await session.flush()

            owner = User(phone="+256733300001", phone_verified=True, role=UserRole.BUSINESS.value)
            session.add(owner)
            await session.flush()
            session.add(UserProfile(user_id=owner.id, first_name="Owner", last_name="Edit"))

            biz = Business(
                owner_id=owner.id,
                name="Edit Kitchen",
                slug=f"edit-{uuid4().hex[:6]}",
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
                name="Wrong Name Cake",
                slug=f"cake-{uuid4().hex[:6]}",
                description="typo description",
                price=Decimal("5000"),
                currency="UGX",
                stock_quantity=3,
            )
            session.add(product)
            await session.commit()
            product_id = str(product.id)

        own = await ac.post(
            "/api/v1/auth/verify-otp",
            json={"phone": "+256733300001", "code": "123456"},
        )
        assert own.status_code == 200
        token = own.json()["access_token"]

        yield {"client": ac, "token": token, "product_id": product_id}

    app.dependency_overrides.clear()
    await engine.dispose()


async def test_owner_can_reedit_product(env):
    ac: AsyncClient = env["client"]
    headers = {"Authorization": f"Bearer {env['token']}"}
    product_id = env["product_id"]

    res = await ac.patch(
        f"/api/v1/products/{product_id}",
        headers=headers,
        json={
            "name": "Correct Cake",
            "description": "fixed description",
            "price": 12000,
            "stock_quantity": 8,
            "status": "ACTIVE",
        },
    )
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["name"] == "Correct Cake"
    assert body["description"] == "fixed description"
    assert Decimal(str(body["price"])) == Decimal("12000")
    assert body["stock_quantity"] == 8
    assert body["status"] == "ACTIVE"
