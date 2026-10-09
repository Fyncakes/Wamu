"""Trust: block + admin suspend."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.database import Base, get_db
from app.core.security import hash_token
from app.main import app
from app.models.user import OtpChallenge

TEST_DB = "sqlite+aiosqlite:///:memory:"


async def _login(ac: AsyncClient, phone: str) -> dict:
    await ac.post("/api/v1/auth/request-otp", json={"phone": phone})
    # seed challenge if rate path skipped — verify with mock
    r = await ac.post(
        "/api/v1/auth/verify-otp",
        json={"phone": phone, "code": "123456"},
    )
    if r.status_code != 200:
        # ensure challenge exists
        return {}
    return {"Authorization": f"Bearer {r.json()['access_token']}", "user": r.json()["user"]}


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
            for phone in ("+256700000111", "+256700000222", "+256700000001"):
                session.add(
                    OtpChallenge(
                        phone=phone,
                        code_hash=hash_token("123456"),
                        expires_at=datetime.now(timezone.utc) + timedelta(minutes=10),
                    )
                )
            await session.commit()

        a = await ac.post(
            "/api/v1/auth/verify-otp",
            json={"phone": "+256700000111", "code": "123456"},
        )
        b = await ac.post(
            "/api/v1/auth/verify-otp",
            json={"phone": "+256700000222", "code": "123456"},
        )
        admin = await ac.post(
            "/api/v1/auth/verify-otp",
            json={"phone": "+256700000001", "code": "123456"},
        )
        assert a.status_code == 200 and b.status_code == 200 and admin.status_code == 200
        yield {
            "client": ac,
            "a": {"Authorization": f"Bearer {a.json()['access_token']}"},
            "b": {"Authorization": f"Bearer {b.json()['access_token']}"},
            "admin": {"Authorization": f"Bearer {admin.json()['access_token']}"},
            "a_id": a.json()["user"]["id"],
            "b_id": b.json()["user"]["id"],
        }

    app.dependency_overrides.clear()
    await engine.dispose()


@pytest.mark.asyncio
async def test_block_prevents_dm(env):
    c = env["client"]
    # A blocks B
    r = await c.post(f"/api/v1/users/me/blocks/{env['b_id']}", headers=env["a"])
    assert r.status_code == 201, r.text

    # A cannot open DM with B
    r = await c.post(
        "/api/v1/chat/conversations",
        headers=env["a"],
        json={"peer_user_id": env["b_id"]},
    )
    assert r.status_code == 403, r.text


@pytest.mark.asyncio
async def test_admin_suspend_blocks_auth(env):
    c = env["client"]
    r = await c.post(
        f"/api/v1/admin/users/{env['b_id']}/suspend",
        headers=env["admin"],
    )
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "SUSPENDED"

    # Suspended user cannot call /users/me with existing token
    r = await c.get("/api/v1/users/me", headers=env["b"])
    assert r.status_code == 401, r.text
