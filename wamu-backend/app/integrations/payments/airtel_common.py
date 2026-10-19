"""Shared Airtel Money Uganda Open API helpers (OAuth, MSISDN, RSA, signing).

Aligns with Airtel Collection/Disbursement v2 (see airtelmoney-py / portal docs):
  POST /auth/oauth2/token          (JSON client_credentials)
  GET  /v1/rsa/encryption-keys
  POST /merchant/v2/payments/      (+ optional x-signature / x-key)
  POST /standard/v2/disbursements/ (RSA-encrypted PIN)
"""

from __future__ import annotations

import base64
import json
import logging
import re
from dataclasses import dataclass
from typing import Any

import httpx

from app.core.config import Settings

logger = logging.getLogger(__name__)

_TOKEN_PATH = "/auth/oauth2/token"
_ENCRYPTION_KEY_PATH = "/v1/rsa/encryption-keys"


def airtel_configured(settings: Settings) -> bool:
    return bool(settings.airtel_client_id and settings.airtel_client_secret)


def normalize_msisdn(phone: str | None) -> str:
    """Airtel UG collection/disbursement expect national number (no 256 / +)."""
    raw = re.sub(r"\D", "", phone or "")
    if raw.startswith("256") and len(raw) >= 12:
        raw = raw[3:]
    if raw.startswith("0") and len(raw) == 10:
        raw = raw[1:]
    return raw


def new_transaction_id() -> str:
    import uuid

    return str(uuid.uuid4())


def country_currency(settings: Settings) -> tuple[str, str]:
    country = (getattr(settings, "airtel_country", None) or "UG").upper()
    currency = (getattr(settings, "airtel_currency", None) or "UGX").upper()
    return country, currency


async def fetch_access_token(
    client: httpx.AsyncClient, settings: Settings
) -> tuple[str | None, dict]:
    """OAuth2 client_credentials — Airtel expects JSON body (not form)."""
    url = f"{settings.airtel_base_url.rstrip('/')}{_TOKEN_PATH}"
    payload = {
        "client_id": settings.airtel_client_id,
        "client_secret": settings.airtel_client_secret,
        "grant_type": "client_credentials",
    }
    token_res = await client.post(
        url,
        json=payload,
        headers={"Content-Type": "application/json", "Accept": "*/*"},
    )
    if token_res.status_code >= 400:
        # Legacy UAT sometimes accepts form-encoded credentials
        token_res = await client.post(url, data=payload)
    if token_res.status_code >= 400:
        return None, {
            "token_error": token_res.status_code,
            "body": token_res.text[:500],
        }
    try:
        data = token_res.json()
    except Exception:
        return None, {"token_error": "invalid_json", "body": token_res.text[:500]}
    access = data.get("access_token")
    if not access:
        return None, {"token_error": "missing_access_token", "body": data}
    return access, {}


async def fetch_encryption_key(
    client: httpx.AsyncClient, settings: Settings, access: str
) -> tuple[str | None, dict]:
    country, currency = country_currency(settings)
    url = f"{settings.airtel_base_url.rstrip('/')}{_ENCRYPTION_KEY_PATH}"
    res = await client.get(
        url,
        headers={
            "Authorization": f"Bearer {access}",
            "Accept": "application/json",
            "X-Country": country,
            "X-Currency": currency,
        },
    )
    if res.status_code >= 400:
        return None, {"encryption_key_error": res.status_code, "body": res.text[:500]}
    try:
        body = res.json()
    except Exception:
        return None, {"encryption_key_error": "invalid_json", "body": res.text[:400]}
    key = (body.get("data") or {}).get("key")
    if not key:
        return None, {"encryption_key_error": "missing_key", "body": body}
    return str(key), {}


def encrypt_pin(public_key: str, pin: str) -> str:
    """RSA PKCS#1 v1.5 encrypt PIN → base64 (Airtel disbursement ``pin`` field)."""
    from Crypto.Cipher import PKCS1_v1_5
    from Crypto.PublicKey import RSA

    key_text = public_key.strip()
    if "-----BEGIN" in key_text:
        rsa_key = RSA.import_key(key_text)
    else:
        rsa_key = RSA.import_key(base64.b64decode(key_text))
    cipher = PKCS1_v1_5.new(rsa_key)
    encrypted = cipher.encrypt(str(pin).encode("utf-8"))
    if encrypted is None:
        raise RuntimeError("Airtel PIN RSA encryption failed")
    return base64.b64encode(encrypted).decode("ascii")


@dataclass
class SignedBody:
    payload: str
    x_signature: str
    x_key: str


def sign_payload(public_key: str, payload: dict[str, Any]) -> SignedBody:
    """AES-256-CBC payload signature + RSA-wrapped key:iv (x-signature / x-key)."""
    from Crypto.Cipher import AES, PKCS1_v1_5
    from Crypto.PublicKey import RSA
    from Crypto.Random import get_random_bytes
    from Crypto.Util.Padding import pad

    payload_str = json.dumps(payload, separators=(",", ":"))
    aes_key = get_random_bytes(32)
    aes_iv = get_random_bytes(16)
    cipher = AES.new(aes_key, AES.MODE_CBC, aes_iv)
    x_signature = base64.b64encode(
        cipher.encrypt(pad(payload_str.encode("utf-8"), AES.block_size))
    ).decode("ascii")

    key_text = public_key.strip()
    if "-----BEGIN" in key_text:
        rsa_key = RSA.import_key(key_text)
    else:
        rsa_key = RSA.import_key(base64.b64decode(key_text))
    key_b64 = base64.b64encode(aes_key).decode("ascii")
    iv_b64 = base64.b64encode(aes_iv).decode("ascii")
    wrapped = PKCS1_v1_5.new(rsa_key).encrypt(f"{key_b64}:{iv_b64}".encode("utf-8"))
    if wrapped is None:
        raise RuntimeError("Airtel x-key RSA encryption failed")
    x_key = base64.b64encode(wrapped).decode("ascii")
    return SignedBody(payload=payload_str, x_signature=x_signature, x_key=x_key)


def parse_transaction_status(data: Any) -> str:
    """Normalize Airtel enquiry / callback status → SUCCESS | FAILED | PENDING."""
    if not isinstance(data, dict):
        return "PENDING"
    txn = data.get("data") if isinstance(data.get("data"), dict) else {}
    nested = txn.get("transaction") if isinstance(txn.get("transaction"), dict) else {}
    if not nested and isinstance(data.get("transaction"), dict):
        nested = data["transaction"]
    status_raw = str(
        nested.get("status")
        or nested.get("transaction_status")
        or txn.get("status")
        or (data.get("status") if not isinstance(data.get("status"), dict) else "")
        or ""
    ).upper()
    # Airtel codes: TS=success, TF=failed, TIP=in progress, TE=expired
    if status_raw in {"TS", "SUCCESS", "SUCCESSFUL", "COMPLETED"}:
        return "SUCCESS"
    if status_raw in {"TF", "FAILED", "FAILURE", "TE"}:
        return "FAILED"
    return "PENDING"


def collection_accepted(http_status: int, body: Any) -> bool:
    """True when USSD-push collection was accepted (not yet paid)."""
    if http_status >= 300:
        return False
    if not isinstance(body, dict):
        return True
    status = body.get("status") if isinstance(body.get("status"), dict) else {}
    if status.get("success") is False:
        return False
    code = str(status.get("response_code") or status.get("code") or "")
    # Explicit failure codes start with DP008… but success is DP00800001001
    if code and code.startswith("DP") and code not in {
        "DP00800001001",
        "DP00900001001",
    }:
        # Ambiguous — treat HTTP 2xx without success:false as accepted
        if status.get("success") is True:
            return True
        msg = str(status.get("message") or "").lower()
        if "fail" in msg or "error" in msg or "invalid" in msg:
            return False
    return True
