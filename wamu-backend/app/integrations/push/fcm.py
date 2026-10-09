"""Push providers — data-only payloads (never message plaintext)."""

from __future__ import annotations

import logging
from typing import Protocol

import httpx

from app.core.config import get_settings

logger = logging.getLogger(__name__)


class PushProvider(Protocol):
    async def send(
        self,
        *,
        token: str,
        title: str,
        body: str,
        data: dict[str, str],
    ) -> dict: ...


class MockPushProvider:
    async def send(
        self,
        *,
        token: str,
        title: str,
        body: str,
        data: dict[str, str],
    ) -> dict:
        logger.info(
            "PUSH mock token=%s… title=%s body=%s data=%s",
            token[:12],
            title,
            body,
            data,
        )
        return {"status": "mock", "token_prefix": token[:12]}


class FcmLegacyPushProvider:
    """
    FCM HTTP legacy (server key) — data-only messages.

    Prefer migrating to HTTP v1 when a service account is available; this path
    is enough for staging with a Firebase cloud messaging server key.
    """

    def __init__(self, server_key: str) -> None:
        self._server_key = server_key

    async def send(
        self,
        *,
        token: str,
        title: str,
        body: str,
        data: dict[str, str],
    ) -> dict:
        # Intentionally omit top-level "notification" so FCM stays data-only.
        # Clients show a generic local notification from `data`.
        payload = {
            "to": token,
            "priority": "high",
            "content_available": True,
            "data": {
                **{k: str(v) for k, v in data.items()},
                "title": title,
                "body": body,
            },
        }
        async with httpx.AsyncClient(timeout=15.0) as client:
            res = await client.post(
                "https://fcm.googleapis.com/fcm/send",
                headers={
                    "Authorization": f"key={self._server_key}",
                    "Content-Type": "application/json",
                },
                json=payload,
            )
        if res.status_code >= 400:
            logger.warning("FCM send failed status=%s body=%s", res.status_code, res.text[:300])
            return {"status": "error", "http_status": res.status_code}
        return {"status": "sent", "provider": "fcm_legacy", "response": res.json()}


def get_push_provider() -> PushProvider:
    settings = get_settings()
    key = (settings.fcm_server_key or "").strip()
    if key:
        return FcmLegacyPushProvider(key)
    return MockPushProvider()


def assert_no_plaintext_leak(data: dict | None, body: str) -> None:
    """Guardrail — push body/data must not carry chat content."""
    forbidden = ("message", "preview", "text", "content")
    blob = " ".join(str(v) for v in (data or {}).values()).lower()
    # Generic labels are fine; reject long bodies that look like chat previews
    if len(body) > 80:
        raise ValueError("push body too long — use a generic label")
    for key in forbidden:
        if key in (data or {}) and len(str((data or {}).get(key, ""))) > 40:
            raise ValueError(f"push data.{key} looks like plaintext content")
    if "📷" in body or "🎤" in body:
        raise ValueError("push body must not include media captions")
    _ = blob  # reserved for future heuristics
