"""Status + Channels (Updates tab / Sprint 3) API smoke tests."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from uuid import uuid4

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.database import Base, get_db
from app.core.security import hash_token
from app.main import app
from app.models.status import StatusUpdate
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
                    phone="+256700000099",
                    code_hash=hash_token("123456"),
                    expires_at=datetime.now(timezone.utc) + timedelta(minutes=10),
                )
            )
            await session.commit()

        r = await ac.post(
            "/api/v1/auth/verify-otp",
            json={"phone": "+256700000099", "code": "123456"},
        )
        assert r.status_code == 200, r.text
        token = r.json()["access_token"]
        headers = {"Authorization": f"Bearer {token}"}
        yield {"client": ac, "headers": headers, "session_factory": session_factory}

    app.dependency_overrides.clear()
    await engine.dispose()


@pytest.mark.asyncio
async def test_channels_endpoint_returns_uganda_channels(env):
    r = await env["client"].get("/api/v1/communities/channels", headers=env["headers"])
    assert r.status_code == 200, r.text
    items = r.json()["items"]
    ids = {c["id"] for c in items}
    assert "kampala-campus" in ids
    assert "uganda-football" in ids
    assert "church-youth" in ids
    assert all(c.get("channel") is True for c in items)
    assert all("member_count" in c and "joined" in c for c in items)


@pytest.mark.asyncio
async def test_communities_join_updates_member_count(env):
    client = env["client"]
    headers = env["headers"]

    before = await client.get("/api/v1/communities", headers=headers)
    assert before.status_code == 200, before.text
    kampala = next(c for c in before.json()["items"] if c["id"] == "kampala-campus")
    assert kampala["joined"] is False

    joined = await client.post("/api/v1/communities/kampala-campus/join", headers=headers)
    assert joined.status_code == 200, joined.text

    after = await client.get("/api/v1/communities", headers=headers)
    assert after.status_code == 200
    kampala2 = next(c for c in after.json()["items"] if c["id"] == "kampala-campus")
    assert kampala2["joined"] is True
    assert kampala2["member_count"] >= 1
    assert "member" in kampala2["members_label"].lower() or kampala2["member_count"] == 1


@pytest.mark.asyncio
async def test_create_group_and_leave_community(env):
    client = env["client"]
    headers = env["headers"]
    sf = env["session_factory"]

    # Second user to invite
    async with sf() as session:
        session.add(
            OtpChallenge(
                phone="+256700000098",
                code_hash=hash_token("123456"),
                expires_at=datetime.now(timezone.utc) + timedelta(minutes=10),
            )
        )
        peer = User(
            phone="+256700000098", phone_verified=True, role=UserRole.CUSTOMER.value
        )
        session.add(peer)
        await session.flush()
        session.add(UserProfile(user_id=peer.id, first_name="Peer"))
        await session.commit()

    group = await client.post(
        "/api/v1/communities/groups",
        headers=headers,
        json={
            "title": "Hostel 5 crew",
            "member_phones": ["+256700000098"],
            "initial_message": "Welcome",
        },
    )
    assert group.status_code == 201, group.text
    assert group.json()["title"] == "Hostel 5 crew"

    await client.post("/api/v1/communities/kampala-campus/join", headers=headers)
    left = await client.post("/api/v1/communities/kampala-campus/leave", headers=headers)
    assert left.status_code == 200, left.text
    assert left.json().get("ok") is True

    after = await client.get("/api/v1/communities", headers=headers)
    kampala = next(c for c in after.json()["items"] if c["id"] == "kampala-campus")
    assert kampala["joined"] is False


@pytest.mark.asyncio
async def test_create_and_list_status(env):
    r = await env["client"].post(
        "/api/v1/status",
        headers=env["headers"],
        json={"body": "Jebale Kampala 🇺🇬", "media_type": "TEXT", "background_color": "#0B6E4F"},
    )
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["is_mine"] is True
    assert body["body"] == "Jebale Kampala 🇺🇬"

    listed = await env["client"].get("/api/v1/status", headers=env["headers"])
    assert listed.status_code == 200
    rows = listed.json()
    assert any(s["id"] == body["id"] for s in rows)
