"""client_message_id idempotency — outbox retries must not duplicate."""

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
                    phone="+256700000066",
                    code_hash=hash_token("123456"),
                    expires_at=datetime.now(timezone.utc) + timedelta(minutes=10),
                )
            )
            peer = User(phone="+256700000055", phone_verified=True, role=UserRole.CUSTOMER.value)
            session.add(peer)
            await session.flush()
            session.add(UserProfile(user_id=peer.id, first_name="Peer", last_name="One"))
            await session.commit()

        r = await ac.post(
            "/api/v1/auth/verify-otp",
            json={"phone": "+256700000066", "code": "123456"},
        )
        assert r.status_code == 200, r.text
        headers = {"Authorization": f"Bearer {r.json()['access_token']}"}
        convo = await ac.post(
            "/api/v1/chat/conversations",
            headers=headers,
            json={"peer_phone": "+256700000055", "initial_message": "hey"},
        )
        assert convo.status_code == 201, convo.text
        yield {"client": ac, "headers": headers, "conversation_id": convo.json()["id"]}

    app.dependency_overrides.clear()
    await engine.dispose()


@pytest.mark.asyncio
async def test_client_message_id_is_idempotent(env):
    client = env["client"]
    headers = env["headers"]
    cid = env["conversation_id"]
    client_id = f"local-{uuid4()}"

    payload = {
        "body": "Same send twice",
        "message_type": "TEXT",
        "client_message_id": client_id,
    }
    a = await client.post(f"/api/v1/chat/conversations/{cid}/messages", headers=headers, json=payload)
    b = await client.post(f"/api/v1/chat/conversations/{cid}/messages", headers=headers, json=payload)
    assert a.status_code == 201, a.text
    assert b.status_code == 201, b.text
    assert a.json()["id"] == b.json()["id"]
    assert a.json()["client_message_id"] == client_id

    listed = await client.get(f"/api/v1/chat/conversations/{cid}/messages", headers=headers)
    assert listed.status_code == 200
    matches = [m for m in listed.json() if m.get("client_message_id") == client_id]
    assert len(matches) == 1
