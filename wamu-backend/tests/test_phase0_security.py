"""
Phase 0 security & integrity tests — run after every config/payment/WS change.

  cd wamu-backend && .venv/bin/pytest -q
"""

from __future__ import annotations

import hashlib
import hmac
import json
from decimal import Decimal
from uuid import uuid4

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from pydantic import ValidationError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.config import Settings
from app.core.database import Base, get_db
from app.core.security import create_access_token, create_ws_ticket, decode_ws_ticket, hash_token
from app.core.webhook_security import sign_webhook_body
from app.main import app
from app.models.user import OtpChallenge, User, UserProfile, UserRole


TEST_DB = "sqlite+aiosqlite:///:memory:"


@pytest_asyncio.fixture
async def client():
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
                    expires_at=__import__("datetime").datetime.now(
                        __import__("datetime").timezone.utc
                    )
                    + __import__("datetime").timedelta(minutes=10),
                )
            )
            await session.commit()
        yield ac
    app.dependency_overrides.clear()
    await engine.dispose()


def test_production_settings_refuse_mocks():
    with pytest.raises(ValidationError):
        Settings(
            environment="production",
            debug=True,
            otp_mock_mode=True,
            payment_mock_auto_success=True,
            secret_key="short",
            cors_origins=["*"],
            payment_webhook_secret="dev-x",
        )


def test_production_settings_accept_hardened():
    s = Settings(
        environment="production",
        debug=False,
        otp_mock_mode=False,
        payment_mock_auto_success=False,
        secret_key="a" * 32 + "strong-production-secret-key",
        cors_origins=["https://wamu.ug"],
        payment_webhook_secret="b" * 32 + "webhook-hmac-secret",
    )
    assert s.is_production


def test_ws_ticket_roundtrip():
    uid = uuid4()
    cid = uuid4()
    ticket = create_ws_ticket(uid, scope="chat", conversation_id=cid)
    payload = decode_ws_ticket(ticket, expected_scope="chat")
    assert payload["sub"] == str(uid)
    assert payload["conversation_id"] == str(cid)
    assert payload["type"] == "ws"


def test_webhook_signature_helpers():
    body = b'{"event_id":"1","provider_reference":"x","status":"SUCCESS"}'
    secret = "test-secret-for-hmac-signing-ok"
    sig = sign_webhook_body(body, secret)
    assert sig.startswith("sha256=")
    digest = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    assert sig == f"sha256={digest}"


@pytest.mark.asyncio
async def test_health(client: AsyncClient):
    r = await client.get("/api/v1/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


@pytest.mark.asyncio
async def test_otp_verify_creates_user(client: AsyncClient):
    r = await client.post(
        "/api/v1/auth/verify-otp",
        json={"phone": "+256700000099", "code": "123456"},
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert "access_token" in body
    assert body["user"]["phone"] == "+256700000099"


@pytest.mark.asyncio
async def test_webhook_rejects_unsigned_when_mock_off(client: AsyncClient, monkeypatch):
    from app.core import config as config_mod
    from app.core import webhook_security as wh

    # Force signature required (simulate non-mock)
    monkeypatch.setattr(
        config_mod.get_settings(),
        "payment_mock_auto_success",
        False,
        raising=False,
    )
    # get_settings is lru_cached — patch module settings used by webhook_security
    class _S:
        is_production = False
        payment_mock_auto_success = False
        payment_webhook_secret = "dev-webhook-secret-change-me"

    monkeypatch.setattr(wh, "get_settings", lambda: _S())

    r = await client.post(
        "/api/v1/payments/webhooks/MOCK",
        json={
            "event_id": "evt-1",
            "provider_reference": "missing",
            "status": "SUCCESS",
        },
    )
    assert r.status_code == 401


@pytest.mark.asyncio
async def test_webhook_accepts_valid_signature(client: AsyncClient, monkeypatch):
    from app.core import webhook_security as wh

    class _S:
        is_production = False
        payment_mock_auto_success = False
        payment_webhook_secret = "dev-webhook-secret-change-me"

    monkeypatch.setattr(wh, "get_settings", lambda: _S())

    payload = {
        "event_id": f"evt-{uuid4().hex[:8]}",
        "provider_reference": "no-such-ref",
        "status": "SUCCESS",
        "amount": None,
    }
    raw = json.dumps(payload).encode()
    sig = sign_webhook_body(raw, _S.payment_webhook_secret)
    r = await client.post(
        "/api/v1/payments/webhooks/MOCK",
        content=raw,
        headers={"Content-Type": "application/json", "X-Wamu-Signature": sig},
    )
    # Payment not found → ignored (not 401)
    assert r.status_code == 200
    assert r.json()["status"] in {"ignored", "duplicate", "processed"}


def test_metrics_endpoint_shape():
    from app.core.metrics import PAYMENT_SUCCESS, metrics

    metrics.incr(PAYMENT_SUCCESS)
    snap = metrics.snapshot()
    assert "counters" in snap
    assert snap["counters"].get(PAYMENT_SUCCESS, 0) >= 1


@pytest.mark.asyncio
async def test_metrics_http(client: AsyncClient):
    r = await client.get("/api/v1/metrics")
    assert r.status_code == 200
    body = r.json()
    assert "counters" in body
    assert body["app"] == "WAMU"
