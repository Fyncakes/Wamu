"""Discover videos — create, list, like, view, follow (Phase 3 thin MVP)."""

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
    Category,
    MemberRole,
    VerificationStatus,
)
from app.models.product import Product
from app.models.user import OtpChallenge, User, UserProfile, UserRole
from app.models.video import BusinessVideo

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
            cat = Category(name="Food", slug=f"food-{uuid4().hex[:6]}")
            session.add(cat)
            await session.flush()
            owner = User(
                phone="+256744400001", phone_verified=True, role=UserRole.BUSINESS.value
            )
            customer = User(
                phone="+256744400002", phone_verified=True, role=UserRole.CUSTOMER.value
            )
            session.add_all([owner, customer])
            await session.flush()
            session.add(UserProfile(user_id=owner.id, first_name="Owner"))
            session.add(UserProfile(user_id=customer.id, first_name="Cust"))
            biz = Business(
                owner_id=owner.id,
                name="Video Kitchen",
                slug=f"vk-{uuid4().hex[:6]}",
                category_id=cat.id,
                verification_status=VerificationStatus.VERIFIED.value,
            )
            session.add(biz)
            await session.flush()
            session.add(
                BusinessMember(business_id=biz.id, user_id=owner.id, role=MemberRole.OWNER.value)
            )
            session.add(
                Product(
                    business_id=biz.id,
                    category_id=cat.id,
                    name="Rolex",
                    slug=f"rx-{uuid4().hex[:6]}",
                    price=Decimal("5000"),
                    currency="UGX",
                    stock_quantity=10,
                )
            )
            await session.commit()
            yield {
                "client": ac,
                "owner_phone": "+256744400001",
                "customer_phone": "+256744400002",
                "biz_id": str(biz.id),
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
async def test_create_list_like_view_follow(env):
    client = env["client"]
    owner_h = {"Authorization": f"Bearer {await _token(env, env['owner_phone'])}"}
    cust_h = {"Authorization": f"Bearer {await _token(env, env['customer_phone'])}"}

    create = await client.post(
        "/api/v1/discover/videos",
        headers=owner_h,
        json={
            "business_id": env["biz_id"],
            "caption": "Fresh rolex this morning",
            "video_url": "https://example.com/rolex.mp4",
            "poster_url": "https://example.com/rolex.jpg",
            "tags": "food,kampala",
        },
    )
    assert create.status_code == 201, create.text
    video = create.json()
    assert video["business_id"] == env["biz_id"]
    assert video["caption"] == "Fresh rolex this morning"
    video_id = video["id"]

    listed = await client.get("/api/v1/discover/videos", headers=cust_h)
    assert listed.status_code == 200, listed.text
    assert any(v["id"] == video_id for v in listed.json())

    like = await client.post(f"/api/v1/discover/videos/{video_id}/like", headers=cust_h)
    assert like.status_code == 200, like.text
    assert like.json()["liked_by_me"] is True
    assert like.json()["like_count"] >= 1

    view = await client.post(f"/api/v1/discover/videos/{video_id}/view", headers=cust_h)
    assert view.status_code == 204, view.text

    async with env["session_factory"]() as session:
        row = await session.get(BusinessVideo, __import__("uuid").UUID(video_id))
        assert row is not None
        assert row.view_count >= 1

    follow = await client.post(
        f"/api/v1/discover/businesses/{env['biz_id']}/follow",
        headers=cust_h,
    )
    assert follow.status_code in (200, 201), follow.text
    assert follow.json().get("following") is True

    listed2 = await client.get("/api/v1/discover/videos", headers=cust_h)
    mine = next(v for v in listed2.json() if v["id"] == video_id)
    assert mine["following"] is True
