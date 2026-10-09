"""Payment webhook HMAC helpers — never trust unsigned provider callbacks."""

from __future__ import annotations

import hashlib
import hmac
import json
from decimal import Decimal
from typing import Any

from fastapi import HTTPException, Request

from app.core.config import get_settings


def sign_webhook_body(body: bytes, secret: str) -> str:
    digest = hmac.new(secret.encode("utf-8"), body, hashlib.sha256).hexdigest()
    return f"sha256={digest}"


def _normalize_sig(header: str) -> str:
    provided = header.strip()
    if not provided.startswith("sha256="):
        provided = f"sha256={provided}"
    return provided


def verify_hmac_sha256(*, body: bytes, signature_header: str | None, secret: str, header_name: str) -> None:
    if not secret:
        raise HTTPException(status_code=500, detail=f"Webhook secret not configured ({header_name})")
    if not signature_header:
        raise HTTPException(status_code=401, detail=f"Missing {header_name}")
    expected = sign_webhook_body(body, secret)
    if not hmac.compare_digest(expected, _normalize_sig(signature_header)):
        raise HTTPException(status_code=401, detail="Invalid webhook signature")


def verify_webhook_signature(*, body: bytes, signature_header: str | None, secret: str) -> None:
    verify_hmac_sha256(
        body=body,
        signature_header=signature_header,
        secret=secret,
        header_name="X-Wamu-Signature",
    )


def _header(request: Request, *names: str) -> str | None:
    for name in names:
        val = request.headers.get(name) or request.headers.get(name.lower())
        if val:
            return val
    return None


def verify_provider_webhook(provider: str, *, body: bytes, request: Request) -> None:
    """
    Provider-aware signature check.

    - MOCK / unknown in Wamu lab: X-Wamu-Signature + PAYMENT_WEBHOOK_SECRET
    - MTN: X-MTN-Signature or X-Callback-Signature + MTN_WEBHOOK_SECRET
    - AIRTEL: X-Airtel-Signature + AIRTEL_WEBHOOK_SECRET

    Local mock-demo (payment_mock_auto_success + non-production) may skip if no sig sent.
    """
    settings = get_settings()
    key = (provider or "MOCK").upper()
    signature = None
    secret = settings.payment_webhook_secret
    header_name = "X-Wamu-Signature"

    if key == "MTN":
        signature = _header(request, "X-MTN-Signature", "X-Callback-Signature", "X-Wamu-Signature")
        secret = settings.mtn_webhook_secret or settings.payment_webhook_secret
        header_name = "X-MTN-Signature"
    elif key == "AIRTEL":
        signature = _header(request, "X-Airtel-Signature", "X-Wamu-Signature")
        secret = settings.airtel_webhook_secret or settings.payment_webhook_secret
        header_name = "X-Airtel-Signature"
    else:
        signature = _header(request, "X-Wamu-Signature")

    allow_unsigned = (
        not settings.is_production
        and settings.payment_mock_auto_success
        and key in {"MOCK", "MTN", "AIRTEL"}
        and not signature
    )
    if allow_unsigned:
        return

    verify_hmac_sha256(
        body=body,
        signature_header=signature,
        secret=secret,
        header_name=header_name,
    )


def normalize_webhook_payload(provider: str, data: dict[str, Any]) -> dict[str, Any]:
    """
    Map provider-specific callback JSON into Wamu WebhookPayload fields:
    event_id, provider_reference, status, amount?, currency?
    """
    key = (provider or "MOCK").upper()
    if key == "MTN":
        # MoMo collection callback-ish shape (flexible for sandbox)
        ref = (
            data.get("provider_reference")
            or data.get("externalId")
            or data.get("financialTransactionId")
            or data.get("referenceId")
            or ""
        )
        status_raw = str(data.get("status") or data.get("financialTransactionStatus") or "").upper()
        if status_raw in {"SUCCESSFUL", "SUCCESS", "COMPLETED"}:
            status = "SUCCESS"
        elif status_raw in {"FAILED", "REJECTED", "TIMEOUT"}:
            status = "FAILED"
        else:
            status = status_raw or "PROCESSING"
        amount = data.get("amount")
        return {
            "event_id": str(data.get("event_id") or data.get("financialTransactionId") or ref or "mtn-evt"),
            "provider_reference": str(ref),
            "status": status,
            "amount": Decimal(str(amount)) if amount is not None else None,
            "currency": data.get("currency") or "UGX",
            "raw": data,
        }
    if key == "AIRTEL":
        txn = data.get("transaction") if isinstance(data.get("transaction"), dict) else {}
        ref = (
            data.get("provider_reference")
            or txn.get("id")
            or data.get("transaction_id")
            or data.get("reference")
            or ""
        )
        status_raw = str(
            data.get("status") or txn.get("status") or data.get("txn_status") or ""
        ).upper()
        if status_raw in {"TS", "SUCCESS", "SUCCESSFUL", "COMPLETED"}:
            status = "SUCCESS"
        elif status_raw in {"TF", "FAILED", "FAILURE"}:
            status = "FAILED"
        else:
            status = status_raw or "PROCESSING"
        amount = data.get("amount") or txn.get("amount")
        return {
            "event_id": str(data.get("event_id") or data.get("id") or ref or "airtel-evt"),
            "provider_reference": str(ref),
            "status": status,
            "amount": Decimal(str(amount)) if amount is not None else None,
            "currency": data.get("currency") or "UGX",
            "raw": data,
        }
    # Already Wamu-shaped
    return data


async def require_valid_webhook(request: Request, provider: str = "MOCK") -> dict[str, Any]:
    """Read body once, verify provider signature, normalize JSON."""
    raw = await request.body()
    verify_provider_webhook(provider, body=raw, request=request)
    try:
        data = json.loads(raw.decode("utf-8") or "{}")
    except json.JSONDecodeError as exc:
        raise HTTPException(status_code=400, detail="Invalid JSON") from exc
    if not isinstance(data, dict):
        raise HTTPException(status_code=400, detail="Webhook body must be a JSON object")
    return normalize_webhook_payload(provider, data)
