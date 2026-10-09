"""Silent hide-for-me vs unsend-for-everyone — no deletion placeholders."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

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
            for phone in ("+256744400001", "+256744400002"):
                session.add(
                    OtpChallenge(
                        phone=phone,
                        code_hash=hash_token("123456"),
                        expires_at=datetime.now(timezone.utc) + timedelta(minutes=10),
                    )
                )
            a = User(phone="+256744400001", phone_verified=True, role=UserRole.CUSTOMER.value)
            b = User(phone="+256744400002", phone_verified=True, role=UserRole.CUSTOMER.value)
            session.add_all([a, b])
            await session.flush()
            session.add(UserProfile(user_id=a.id, first_name="Ada", last_name="Chat"))
            session.add(UserProfile(user_id=b.id, first_name="Ben", last_name="Chat"))
            await session.commit()
            peer_id = str(b.id)

        tokens = {}
        for phone, key in (("+256744400001", "a"), ("+256744400002", "b")):
            r = await ac.post("/api/v1/auth/verify-otp", json={"phone": phone, "code": "123456"})
            assert r.status_code == 200, r.text
            tokens[key] = {"Authorization": f"Bearer {r.json()['access_token']}"}

        yield {"client": ac, "ha": tokens["a"], "hb": tokens["b"], "peer_id": peer_id}

    app.dependency_overrides.clear()
    await engine.dispose()


async def _start_and_message(client, ha, hb, peer_id: str, body: str) -> tuple[str, str]:
    started = await client.post(
        "/api/v1/chat/conversations",
        headers=ha,
        json={"peer_user_id": peer_id, "initial_message": body},
    )
    assert started.status_code in (200, 201), started.text
    convo_id = started.json()["id"]
    msgs = await client.get(f"/api/v1/chat/conversations/{convo_id}/messages", headers=ha)
    assert msgs.status_code == 200, msgs.text
    mid = msgs.json()[0]["id"]
    return convo_id, mid


def _ids(payload) -> set[str]:
    if isinstance(payload, list):
        return {row["id"] for row in payload}
    return {row["id"] for row in payload.get("items") or payload.get("conversations") or []}


@pytest.mark.asyncio
async def test_hide_conversation_is_local_only(env):
    client, ha, hb = env["client"], env["ha"], env["hb"]
    convo_id, _ = await _start_and_message(client, ha, hb, env["peer_id"], "hello silent")

    hide = await client.post(f"/api/v1/chat/conversations/{convo_id}/hide", headers=ha)
    assert hide.status_code == 200, hide.text

    mine = await client.get("/api/v1/chat/conversations", headers=ha)
    theirs = await client.get("/api/v1/chat/conversations", headers=hb)
    assert convo_id not in _ids(mine.json())
    assert convo_id in _ids(theirs.json())


@pytest.mark.asyncio
async def test_delete_for_me_does_not_unsend(env):
    client, ha, hb = env["client"], env["ha"], env["hb"]
    convo_id, mid = await _start_and_message(client, ha, hb, env["peer_id"], "keep on peer")

    gone = await client.post(
        f"/api/v1/chat/conversations/{convo_id}/messages/delete",
        headers=ha,
        json={"message_ids": [mid], "scope": "me"},
    )
    assert gone.status_code == 200, gone.text
    assert mid in gone.json()["deleted_ids"]

    a_msgs = await client.get(f"/api/v1/chat/conversations/{convo_id}/messages", headers=ha)
    b_msgs = await client.get(f"/api/v1/chat/conversations/{convo_id}/messages", headers=hb)
    assert mid not in {m["id"] for m in a_msgs.json()}
    assert mid in {m["id"] for m in b_msgs.json()}
    assert all("deleted" not in (m.get("body") or "").lower() for m in b_msgs.json())


@pytest.mark.asyncio
async def test_delete_for_everyone_removes_silently(env):
    client, ha, hb = env["client"], env["ha"], env["hb"]
    convo_id, mid = await _start_and_message(client, ha, hb, env["peer_id"], "unsend this")

    gone = await client.post(
        f"/api/v1/chat/conversations/{convo_id}/messages/delete",
        headers=ha,
        json={"message_ids": [mid], "scope": "everyone"},
    )
    assert gone.status_code == 200, gone.text

    a_msgs = await client.get(f"/api/v1/chat/conversations/{convo_id}/messages", headers=ha)
    b_msgs = await client.get(f"/api/v1/chat/conversations/{convo_id}/messages", headers=hb)
    assert mid not in {m["id"] for m in a_msgs.json()}
    assert mid not in {m["id"] for m in b_msgs.json()}
    assert a_msgs.json() == [] or all("was deleted" not in (m.get("body") or "").lower() for m in a_msgs.json())
    assert b_msgs.json() == [] or all("was deleted" not in (m.get("body") or "").lower() for m in b_msgs.json())
