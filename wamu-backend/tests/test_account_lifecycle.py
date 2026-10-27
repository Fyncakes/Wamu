"""Deactivate, self-delete, and admin delete remove personal data from Wamu."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from uuid import UUID

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.database import Base, get_db
from app.core.security import hash_token
from app.main import app
from app.models.user import OtpChallenge, User

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
            "db": session_factory,
            "a": {"Authorization": f"Bearer {a.json()['access_token']}"},
            "b": {"Authorization": f"Bearer {b.json()['access_token']}"},
            "admin": {"Authorization": f"Bearer {admin.json()['access_token']}"},
            "a_id": a.json()["user"]["id"],
            "b_id": b.json()["user"]["id"],
            "a_phone": "+256700000111",
            "b_phone": "+256700000222",
        }

    app.dependency_overrides.clear()
    await engine.dispose()


async def _seed_otp(session_factory, phone: str) -> None:
    async with session_factory() as session:
        session.add(
            OtpChallenge(
                phone=phone,
                code_hash=hash_token("123456"),
                expires_at=datetime.now(timezone.utc) + timedelta(minutes=10),
            )
        )
        await session.commit()


@pytest.mark.asyncio
async def test_deactivate_then_otp_reactivates(env):
    c = env["client"]
    r = await c.post("/api/v1/users/me/deactivate", headers=env["a"])
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "deactivated"

    r = await c.get("/api/v1/users/me", headers=env["a"])
    assert r.status_code == 401

    await _seed_otp(env["db"], env["a_phone"])
    r = await c.post(
        "/api/v1/auth/verify-otp",
        json={"phone": env["a_phone"], "code": "123456"},
    )
    assert r.status_code == 200, r.text
    assert r.json()["user"]["status"] == "ACTIVE"
    headers = {"Authorization": f"Bearer {r.json()['access_token']}"}
    r = await c.get("/api/v1/users/me", headers=headers)
    assert r.status_code == 200


@pytest.mark.asyncio
async def test_admin_suspend_blocks_otp_until_activate(env):
    c = env["client"]
    r = await c.post(
        f"/api/v1/admin/users/{env['b_id']}/suspend",
        headers=env["admin"],
    )
    assert r.status_code == 200, r.text

    await _seed_otp(env["db"], env["b_phone"])
    r = await c.post(
        "/api/v1/auth/verify-otp",
        json={"phone": env["b_phone"], "code": "123456"},
    )
    assert r.status_code == 403, r.text

    r = await c.post(
        f"/api/v1/admin/users/{env['b_id']}/activate",
        headers=env["admin"],
    )
    assert r.status_code == 200, r.text

    await _seed_otp(env["db"], env["b_phone"])
    r = await c.post(
        "/api/v1/auth/verify-otp",
        json={"phone": env["b_phone"], "code": "123456"},
    )
    assert r.status_code == 200, r.text


@pytest.mark.asyncio
async def test_self_delete_scrubs_phone_and_frees_number(env):
    c = env["client"]
    r = await c.post(
        "/api/v1/users/me/delete",
        headers=env["a"],
        json={"confirm": "nope"},
    )
    assert r.status_code == 400

    r = await c.post(
        "/api/v1/users/me/delete",
        headers=env["a"],
        json={"confirm": "DELETE"},
    )
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "deleted"

    r = await c.get("/api/v1/users/me", headers=env["a"])
    assert r.status_code == 401

    async with env["db"]() as session:
        row = await session.scalar(select(User).where(User.id == UUID(env["a_id"])))
        assert row is not None
        assert row.status == "DELETED"
        assert row.phone.startswith("d")
        assert row.phone != env["a_phone"]

    await _seed_otp(env["db"], env["a_phone"])
    r = await c.post(
        "/api/v1/auth/verify-otp",
        json={"phone": env["a_phone"], "code": "123456"},
    )
    assert r.status_code == 200, r.text
    assert r.json()["user"]["id"] != env["a_id"]
    assert r.json()["is_new_user"] is True


@pytest.mark.asyncio
async def test_admin_delete_user(env):
    c = env["client"]
    r = await c.post(
        f"/api/v1/admin/users/{env['b_id']}/delete",
        headers=env["admin"],
        json={"confirm": "DELETE"},
    )
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "deleted"

    r = await c.get("/api/v1/users/me", headers=env["b"])
    assert r.status_code == 401

    async with env["db"]() as session:
        row = await session.scalar(select(User).where(User.id == UUID(env["b_id"])))
        assert row is not None
        assert row.status == "DELETED"
        assert row.phone.startswith("d")
