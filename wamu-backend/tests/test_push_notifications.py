"""Device push tokens + data-only FCM enqueue."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock, patch
from uuid import uuid4

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.database import Base, get_db
from app.core.security import hash_token
from app.integrations.push.fcm import assert_no_plaintext_leak
from app.main import app
from app.models.chat import ConversationMember
from app.models.user import OtpChallenge, User, UserProfile, UserRole
from app.services.chat import _enqueue_message_pushes

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
                    phone="+256700000266",
                    code_hash=hash_token("123456"),
                    expires_at=datetime.now(timezone.utc) + timedelta(minutes=10),
                )
            )
            peer = User(
                phone="+256700000255", phone_verified=True, role=UserRole.CUSTOMER.value
            )
            session.add(peer)
            await session.flush()
            session.add(UserProfile(user_id=peer.id, first_name="Push", last_name="Peer"))
            await session.commit()

        r = await ac.post(
            "/api/v1/auth/verify-otp",
            json={"phone": "+256700000266", "code": "123456"},
        )
        assert r.status_code == 200, r.text
        headers = {"Authorization": f"Bearer {r.json()['access_token']}"}
        yield {"client": ac, "headers": headers, "session_factory": session_factory}

    app.dependency_overrides.clear()
    await engine.dispose()


def test_assert_no_plaintext_reject_long_body():
    with pytest.raises(ValueError):
        assert_no_plaintext_leak({"type": "NEW_MESSAGE"}, "x" * 100)


def test_assert_no_plaintext_ok_generic():
    assert_no_plaintext_leak(
        {"type": "NEW_MESSAGE", "conversation_id": str(uuid4())},
        "New message",
    )


@pytest.mark.asyncio
async def test_upsert_push_token(env):
    client = env["client"]
    headers = env["headers"]
    token = f"fcm-test-{uuid4().hex}"
    r = await client.put(
        "/api/v1/devices/push-token",
        headers=headers,
        json={"token": token, "platform": "android"},
    )
    assert r.status_code == 200, r.text
    assert r.json()["token"] == token
    assert r.json()["platform"] == "android"

    # Idempotent refresh
    r2 = await client.put(
        "/api/v1/devices/push-token",
        headers=headers,
        json={"token": token, "platform": "android"},
    )
    assert r2.status_code == 200


@pytest.mark.asyncio
async def test_enqueue_skips_muted_and_uses_generic_copy():
    convo_id = uuid4()
    sender = uuid4()
    peer = uuid4()
    muted_peer = uuid4()
    members = [
        ConversationMember(
            conversation_id=convo_id, user_id=sender, muted=False
        ),
        ConversationMember(
            conversation_id=convo_id, user_id=peer, muted=False
        ),
        ConversationMember(
            conversation_id=convo_id, user_id=muted_peer, muted=True
        ),
    ]
    with patch("app.workers.tasks.send_push_notification") as task:
        task.delay = MagicMock()
        _enqueue_message_pushes(
            conversation_id=convo_id, sender_id=sender, members=members
        )
        assert task.delay.call_count == 1
        args, kwargs = task.delay.call_args
        assert args[0] == str(peer)
        assert args[1] == "Wamu"
        assert args[2] == "New message"
        assert "conversation_id" in args[3]
        assert "preview" not in args[3]
