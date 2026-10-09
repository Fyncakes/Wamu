"""MTN / Airtel webhook signature + payload normalization tests."""

from __future__ import annotations

import json

import pytest
from fastapi import HTTPException
from starlette.requests import Request

from app.core.webhook_security import (
    normalize_webhook_payload,
    sign_webhook_body,
    verify_provider_webhook,
)


def _request(body: bytes, headers: dict[str, str]) -> Request:
    scope = {
        "type": "http",
        "method": "POST",
        "path": "/api/v1/payments/webhooks/MTN",
        "headers": [(k.lower().encode(), v.encode()) for k, v in headers.items()],
    }

    async def receive():
        return {"type": "http.request", "body": body, "more_body": False}

    return Request(scope, receive)


def test_normalize_mtn_successful_callback():
    raw = {
        "externalId": "MTN-abc",
        "status": "SUCCESSFUL",
        "amount": "15000",
        "currency": "UGX",
        "financialTransactionId": "ftx-1",
    }
    out = normalize_webhook_payload("MTN", raw)
    assert out["status"] == "SUCCESS"
    assert out["provider_reference"] == "MTN-abc"
    assert out["event_id"] == "ftx-1"


def test_normalize_airtel_success():
    raw = {
        "transaction": {"id": "AIR-1", "status": "TS", "amount": "2000"},
    }
    out = normalize_webhook_payload("AIRTEL", raw)
    assert out["status"] == "SUCCESS"
    assert out["provider_reference"] == "AIR-1"


def test_mtn_signature_required_when_mocks_off(monkeypatch):
    from app.core import webhook_security as wh

    class _S:
        is_production = False
        payment_mock_auto_success = False
        payment_webhook_secret = "fallback-secret"
        mtn_webhook_secret = "mtn-secret-key-for-tests"
        airtel_webhook_secret = ""

    monkeypatch.setattr(wh, "get_settings", lambda: _S())
    body = b'{"externalId":"x","status":"SUCCESSFUL"}'
    req = _request(body, {})
    with pytest.raises(HTTPException) as ei:
        verify_provider_webhook("MTN", body=body, request=req)
    assert ei.value.status_code == 401

    sig = sign_webhook_body(body, _S.mtn_webhook_secret)
    req2 = _request(body, {"X-MTN-Signature": sig})
    verify_provider_webhook("MTN", body=body, request=req2)


def test_airtel_signature_ok(monkeypatch):
    from app.core import webhook_security as wh

    class _S:
        is_production = False
        payment_mock_auto_success = False
        payment_webhook_secret = "fallback"
        mtn_webhook_secret = ""
        airtel_webhook_secret = "airtel-secret-key"

    monkeypatch.setattr(wh, "get_settings", lambda: _S())
    body = json.dumps({"transaction": {"id": "a1", "status": "TS"}}).encode()
    sig = sign_webhook_body(body, _S.airtel_webhook_secret)
    req = _request(body, {"X-Airtel-Signature": sig})
    verify_provider_webhook("AIRTEL", body=body, request=req)
