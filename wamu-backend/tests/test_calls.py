"""Voice/video call REST flow — ICE must include TURN for carrier phones."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from unittest.mock import patch

import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.database import Base, get_db
from app.core.security import hash_token
from app.main import app
from app.models.user import OtpChallenge

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

    phones = ("+256744400001", "+256744400002")
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        async with session_factory() as session:
            for phone in phones:
                session.add(
                    OtpChallenge(
                        phone=phone,
                        code_hash=hash_token("123456"),
                        expires_at=datetime.now(timezone.utc) + timedelta(minutes=10),
                    )
                )
            await session.commit()

        tokens = {}
        ids = {}
        for phone in phones:
            res = await ac.post(
                "/api/v1/auth/verify-otp",
                json={"phone": phone, "code": "123456"},
            )
            assert res.status_code == 200, res.text
            tokens[phone] = res.json()["access_token"]
            me = await ac.get(
                "/api/v1/users/me",
                headers={"Authorization": f"Bearer {tokens[phone]}"},
            )
            assert me.status_code == 200
            ids[phone] = me.json()["id"]

        yield {"client": ac, "tokens": tokens, "ids": ids, "phones": phones}

    app.dependency_overrides.clear()
    await engine.dispose()


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _has_turn(ice: list) -> bool:
    for entry in ice:
        urls = str(entry.get("urls", "")).lower()
        if "turn:" in urls or "turns:" in urls:
            return True
    return False


async def test_voice_call_includes_turn_and_accept_end(env):
    ac = env["client"]
    caller_phone, callee_phone = env["phones"]
    caller = env["tokens"][caller_phone]
    callee = env["tokens"][callee_phone]
    callee_id = env["ids"][callee_phone]

    with patch("app.workers.tasks.send_push_notification") as push:
        push.delay = push
        start = await ac.post(
            "/api/v1/calls",
            headers=_auth(caller),
            json={"callee_id": callee_id, "call_type": "VOICE"},
        )
    assert start.status_code == 201, start.text
    body = start.json()
    assert body["status"] == "RINGING"
    assert body["call_type"] == "VOICE"
    assert _has_turn(body["ice_servers"]), body["ice_servers"]
    call_id = body["id"]
    assert push.called
    push_args = push.call_args[0]
    assert push_args[0] == callee_id
    assert push_args[2] == "Incoming voice call"
    assert push_args[3]["type"] == "INCOMING_CALL"
    assert push_args[3]["call_id"] == call_id

    ticket = await ac.post("/api/v1/calls/ws-ticket", headers=_auth(caller))
    assert ticket.status_code == 200
    assert ticket.json()["ticket"]

    accepted = await ac.post(f"/api/v1/calls/{call_id}/accept", headers=_auth(callee))
    assert accepted.status_code == 200, accepted.text
    assert accepted.json()["status"] == "ACCEPTED"
    assert _has_turn(accepted.json()["ice_servers"])

    ended = await ac.post(f"/api/v1/calls/{call_id}/end", headers=_auth(caller))
    assert ended.status_code == 200
    assert ended.json()["status"] == "ENDED"


async def test_video_call_flow_and_reject(env):
    ac = env["client"]
    caller_phone, callee_phone = env["phones"]
    caller = env["tokens"][caller_phone]
    callee = env["tokens"][callee_phone]
    callee_id = env["ids"][callee_phone]

    with patch("app.workers.tasks.send_push_notification") as push:
        push.delay = push
        start = await ac.post(
            "/api/v1/calls",
            headers=_auth(caller),
            json={"callee_id": callee_id, "call_type": "VIDEO"},
        )
    assert start.status_code == 201, start.text
    body = start.json()
    assert body["call_type"] == "VIDEO"
    assert _has_turn(body["ice_servers"]), body["ice_servers"]
    call_id = body["id"]
    assert push.call_args[0][2] == "Incoming video call"
    assert push.call_args[0][3]["call_type"] == "VIDEO"

    rejected = await ac.post(f"/api/v1/calls/{call_id}/reject", headers=_auth(callee))
    assert rejected.status_code == 200
    assert rejected.json()["status"] == "REJECTED"


async def test_caller_cancel_enqueues_missed_call_push(env):
    ac = env["client"]
    caller_phone, callee_phone = env["phones"]
    caller = env["tokens"][caller_phone]
    callee_id = env["ids"][callee_phone]

    with patch("app.workers.tasks.send_push_notification") as push:
        push.delay = push
        start = await ac.post(
            "/api/v1/calls",
            headers=_auth(caller),
            json={"callee_id": callee_id, "call_type": "VOICE"},
        )
        assert start.status_code == 201, start.text
        call_id = start.json()["id"]
        push.reset_mock()
        ended = await ac.post(f"/api/v1/calls/{call_id}/end", headers=_auth(caller))
    assert ended.status_code == 200
    assert ended.json()["status"] == "CANCELLED"
    assert push.called
    assert push.call_args[0][3]["type"] == "CALL_CANCELLED"
    assert push.call_args[0][3]["call_id"] == call_id


async def test_health_rails_marks_carrier_calls_ready():
    from app.services.staging_readiness import rails_readiness

    r = rails_readiness()
    assert r["ice_includes_turn"] is True
    assert r["ready_for_carrier_calls"] is True
    assert r["ice_server_count"] >= 3
