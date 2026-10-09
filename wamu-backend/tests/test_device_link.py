"""QR device-link: one-time hashed token, no phone/password in payload."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from urllib.parse import parse_qs, urlparse

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.database import Base, get_db
from app.core.security import hash_token
from app.main import app
from app.models.user import DeviceLinkChallenge, OtpChallenge, User, UserProfile, UserRole

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
                    phone="+256744400099",
                    code_hash=hash_token("123456"),
                    expires_at=datetime.now(timezone.utc) + timedelta(minutes=10),
                )
            )
            user = User(phone="+256744400099", phone_verified=True, role=UserRole.CUSTOMER.value)
            session.add(user)
            await session.flush()
            session.add(UserProfile(user_id=user.id, first_name="Kolyanga"))
            await session.commit()

        r = await ac.post(
            "/api/v1/auth/verify-otp", json={"phone": "+256744400099", "code": "123456"}
        )
        assert r.status_code == 200, r.text
        headers = {"Authorization": f"Bearer {r.json()['access_token']}"}
        yield {"client": ac, "headers": headers, "sessions": session_factory}

    app.dependency_overrides.clear()
    await engine.dispose()


@pytest.mark.asyncio
async def test_qr_payload_has_no_secrets(env):
    ac, ha = env["client"], env["headers"]
    created = await ac.post("/api/v1/auth/device-link", headers=ha)
    assert created.status_code == 200, created.text
    body = created.json()
    qr = body["qr"]
    assert "+256" not in qr
    assert "password" not in qr.lower()
    assert "Kolyanga" not in qr
    parsed = urlparse(qr)
    assert parsed.path.endswith("/link")
    assert parse_qs(parsed.query).get("k")


@pytest.mark.asyncio
async def test_claim_logs_in_other_device(env):
    ac, ha = env["client"], env["headers"]
    created = await ac.post("/api/v1/auth/device-link", headers=ha)
    qr = created.json()["qr"]
    claim = await ac.post(
        "/api/v1/auth/device-link/claim",
        json={"token": qr, "device_name": "Pixel demo"},
    )
    assert claim.status_code == 200, claim.text
    data = claim.json()
    assert data["access_token"]
    assert data["refresh_token"]
    assert data["user"]["phone"] == "+256744400099"

    again = await ac.post("/api/v1/auth/device-link/claim", json={"token": qr})
    assert again.status_code == 400

    status = await ac.get(
        f"/api/v1/auth/device-link/{created.json()['id']}", headers=ha
    )
    assert status.status_code == 200
    assert status.json()["status"] == "claimed"
    assert status.json()["device_name"] == "Pixel demo"


@pytest.mark.asyncio
async def test_unauthenticated_cannot_mint_qr(env):
    ac = env["client"]
    r = await ac.post("/api/v1/auth/device-link")
    assert r.status_code == 401


@pytest.mark.asyncio
async def test_expired_code_rejected(env):
    from sqlalchemy import select

    ac, ha = env["client"], env["headers"]
    created = await ac.post("/api/v1/auth/device-link", headers=ha)
    token = parse_qs(urlparse(created.json()["qr"]).query)["k"][0]
    async with env["sessions"]() as session:
        challenge = (
            await session.execute(
                select(DeviceLinkChallenge).where(
                    DeviceLinkChallenge.token_hash == hash_token(token)
                )
            )
        ).scalar_one()
        challenge.expires_at = datetime.now(timezone.utc) - timedelta(seconds=5)
        await session.commit()
    bad = await ac.post("/api/v1/auth/device-link/claim", json={"token": token})
    assert bad.status_code == 400
