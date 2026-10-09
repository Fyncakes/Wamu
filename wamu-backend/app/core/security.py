"""
Security helpers: JWT, password/OTP hashing, refresh-token hashing.

Access tokens are short-lived JWTs. Refresh tokens are opaque random strings
stored only as hashes in the sessions table (never plaintext).
"""

from __future__ import annotations

import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from typing import Any
from uuid import UUID

import jwt
from passlib.context import CryptContext

from app.core.config import get_settings

pwd_context = CryptContext(schemes=["argon2"], deprecated="auto")
settings = get_settings()

ALGORITHM = "HS256"


def hash_secret(value: str) -> str:
    return pwd_context.hash(value)


def verify_secret(plain: str, hashed: str) -> bool:
    return pwd_context.verify(plain, hashed)


def hash_token(token: str) -> str:
    """SHA-256 for refresh tokens / OTP codes (fast, non-reversible lookup)."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def create_access_token(
    subject: str | UUID,
    *,
    role: str = "CUSTOMER",
    extra: dict[str, Any] | None = None,
) -> str:
    expire = datetime.now(timezone.utc) + timedelta(
        minutes=settings.access_token_expire_minutes
    )
    payload: dict[str, Any] = {
        "sub": str(subject),
        "role": role,
        "exp": expire,
        "type": "access",
    }
    if extra:
        payload.update(extra)
    return jwt.encode(payload, settings.secret_key, algorithm=ALGORITHM)


def decode_access_token(token: str) -> dict[str, Any]:
    payload = jwt.decode(token, settings.secret_key, algorithms=[ALGORITHM])
    if payload.get("type") not in (None, "access"):
        # Allow legacy tokens without type; reject ws tickets used as access
        if payload.get("type") == "ws":
            raise jwt.InvalidTokenError("WS ticket is not an access token")
    return payload


def create_ws_ticket(
    subject: str | UUID,
    *,
    scope: str,
    conversation_id: str | UUID | None = None,
) -> str:
    """Short-lived ticket for WebSocket handshake (prefer over access JWT in URLs)."""
    expire = datetime.now(timezone.utc) + timedelta(seconds=settings.ws_ticket_expire_seconds)
    payload: dict[str, Any] = {
        "sub": str(subject),
        "exp": expire,
        "type": "ws",
        "scope": scope,  # "chat" | "calls"
    }
    if conversation_id is not None:
        payload["conversation_id"] = str(conversation_id)
    return jwt.encode(payload, settings.secret_key, algorithm=ALGORITHM)


def decode_ws_ticket(ticket: str, *, expected_scope: str) -> dict[str, Any]:
    payload = jwt.decode(ticket, settings.secret_key, algorithms=[ALGORITHM])
    if payload.get("type") != "ws":
        raise jwt.InvalidTokenError("Not a WS ticket")
    if payload.get("scope") != expected_scope:
        raise jwt.InvalidTokenError("WS ticket scope mismatch")
    return payload


def generate_refresh_token() -> str:
    return secrets.token_urlsafe(48)


def generate_otp(length: int | None = None) -> str:
    n = length or settings.otp_length
    # Cryptographically random numeric OTP
    upper = 10**n
    return str(secrets.randbelow(upper)).zfill(n)
