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


def build_fcm_payload(
    *,
    token: str,
    title: str,
    body: str,
    data: dict[str, str],
) -> dict:
    """OS-visible notification plus data so a tap can open the conversation.

    Title and body stay generic. Message text never goes in this payload.
    Incoming calls use the wamu_calls Android channel (max importance).
    """
    safe = {k: str(v) for k, v in data.items()}
    channel = safe.get("android_channel_id") or (
        "wamu_calls" if safe.get("type") == "INCOMING_CALL" else "wamu_messages"
    )
    notification: dict[str, str] = {
        "title": title,
        "body": body,
        "sound": "default",
        "android_channel_id": channel,
    }
    # Collapse / replace prior ring for the same call id.
    call_id = safe.get("call_id")
    if call_id and safe.get("type") in {"INCOMING_CALL", "CALL_CANCELLED"}:
        notification["tag"] = f"wamu_call_{call_id}"
    return {
        "to": token,
        "priority": "high",
        "content_available": True,
        "notification": notification,
        "data": {
            **safe,
            "title": title,
            "body": body,
            "android_channel_id": channel,
        },
    }


class FcmLegacyPushProvider:
    """
    FCM HTTP legacy (server key).

    The notification block is a generic label so Android can show it when Wamu
    is in the background or closed. The data block carries the conversation id.
    Prefer HTTP v1 when a service account is available.
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
        payload = build_fcm_payload(token=token, title=title, body=body, data=data)
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
