"""Read receipts privacy — WhatsApp-style reciprocal toggle for 1:1."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from uuid import UUID

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import selectinload

from app.core.database import Base, get_db
from app.core.security import hash_token
from app.main import app
from app.models.chat import Message
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
                    phone="+256700000166",
                    code_hash=hash_token("123456"),
                    expires_at=datetime.now(timezone.utc) + timedelta(minutes=10),
                )
            )
            peer = User(
                phone="+256700000155", phone_verified=True, role=UserRole.CUSTOMER.value
            )
            session.add(peer)
            await session.flush()
            session.add(UserProfile(user_id=peer.id, first_name="Peer", last_name="R"))
            await session.commit()
            peer_id = peer.id

        r = await ac.post(
            "/api/v1/auth/verify-otp",
            json={"phone": "+256700000166", "code": "123456"},
        )
        assert r.status_code == 200, r.text
        sender_headers = {"Authorization": f"Bearer {r.json()['access_token']}"}

        # Log peer in via OTP
        async with session_factory() as session:
            session.add(
                OtpChallenge(
                    phone="+256700000155",
                    code_hash=hash_token("123456"),
                    expires_at=datetime.now(timezone.utc) + timedelta(minutes=10),
                )
            )
            await session.commit()
        pr = await ac.post(
            "/api/v1/auth/verify-otp",
            json={"phone": "+256700000155", "code": "123456"},
        )
        assert pr.status_code == 200, pr.text
        peer_headers = {"Authorization": f"Bearer {pr.json()['access_token']}"}

        convo = await ac.post(
            "/api/v1/chat/conversations",
            headers=sender_headers,
            json={"peer_phone": "+256700000155", "initial_message": "hello receipts"},
        )
        assert convo.status_code == 201, convo.text
        yield {
            "client": ac,
            "sender": sender_headers,
            "peer": peer_headers,
            "conversation_id": convo.json()["id"],
            "peer_id": peer_id,
            "session_factory": session_factory,
        }

    app.dependency_overrides.clear()
    await engine.dispose()


@pytest.mark.asyncio
async def test_privacy_patch_round_trip(env):
    client = env["client"]
    headers = env["peer"]
    r = await client.patch(
        "/api/v1/users/me/privacy",
        headers=headers,
        json={"show_read_receipts": False},
    )
    assert r.status_code == 200, r.text
    assert r.json()["profile"]["show_read_receipts"] is False

    me = await client.get("/api/v1/users/me", headers=headers)
    assert me.json()["profile"]["show_read_receipts"] is False


@pytest.mark.asyncio
async def test_reader_hides_receipts_caps_at_delivered(env):
    client = env["client"]
    cid = env["conversation_id"]

    # Peer turns off receipts
    await client.patch(
        "/api/v1/users/me/privacy",
        headers=env["peer"],
        json={"show_read_receipts": False},
    )

    # Opening the thread would normally mark READ
    msgs = await client.get(
        f"/api/v1/chat/conversations/{cid}/messages",
        headers=env["peer"],
    )
    assert msgs.status_code == 200, msgs.text

    async with env["session_factory"]() as session:
        row = await session.scalar(
            select(Message)
            .where(Message.conversation_id == UUID(cid))
            .order_by(Message.created_at.desc())
        )
        assert row is not None
        assert row.status == "DELIVERED"


@pytest.mark.asyncio
async def test_default_open_marks_read(env):
    client = env["client"]
    cid = env["conversation_id"]

    msgs = await client.get(
        f"/api/v1/chat/conversations/{cid}/messages",
        headers=env["peer"],
    )
    assert msgs.status_code == 200, msgs.text

    async with env["session_factory"]() as session:
        row = await session.scalar(
            select(Message)
            .where(Message.conversation_id == UUID(cid))
            .order_by(Message.created_at.desc())
        )
        assert row is not None
        assert row.status == "READ"


@pytest.mark.asyncio
async def test_viewer_mask_hides_blue_ticks(env):
    client = env["client"]
    cid = env["conversation_id"]

    # Peer reads → READ in DB
    await client.get(
        f"/api/v1/chat/conversations/{cid}/messages",
        headers=env["peer"],
    )

    # Sender turns off receipts → should see DELIVERED not READ
    await client.patch(
        "/api/v1/users/me/privacy",
        headers=env["sender"],
        json={"show_read_receipts": False},
    )
    inbox = await client.get("/api/v1/chat/conversations", headers=env["sender"])
    assert inbox.status_code == 200
    mine = next(c for c in inbox.json() if c["id"] == cid)
    assert mine["last_message_from_me"] is True
    assert mine["last_message_status"] == "DELIVERED"

    thread = await client.get(
        f"/api/v1/chat/conversations/{cid}/messages",
        headers=env["sender"],
    )
    assert thread.status_code == 200
    own = [m for m in thread.json() if m.get("body") == "hello receipts"]
    assert own
    assert own[0]["status"] == "DELIVERED"

    # DB still READ
    async with env["session_factory"]() as session:
        row = await session.scalar(
            select(Message)
            .options(selectinload(Message.reactions))
            .where(Message.conversation_id == UUID(cid))
            .order_by(Message.created_at.desc())
        )
        assert row.status == "READ"
