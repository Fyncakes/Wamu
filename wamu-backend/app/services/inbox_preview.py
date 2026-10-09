"""Inbox last-message preview strings — scan-friendly labels for list rows."""

from __future__ import annotations

import re

from app.models.chat import Message


_DATA_SAVER = re.compile(r"\s*\(data saver\)\s*", re.IGNORECASE)


def snippet_for_reaction(body: str | None, *, limit: int = 40) -> str:
    text = _DATA_SAVER.sub(" ", (body or "").strip())
    for prefix in ("📷", "🎤", "📄"):
        if text.startswith(prefix):
            text = text[len(prefix) :].strip()
            break
    text = re.sub(r"\s+", " ", text)
    if not text:
        return "message"
    if len(text) > limit:
        return text[: limit - 1].rstrip() + "…"
    return text


def message_preview_text(msg: Message) -> str:
    """Normalize message body for conversation list (≤120 chars)."""
    body = _DATA_SAVER.sub(" ", (msg.body or "").strip())
    body = re.sub(r"\s+", " ", body).strip()
    mt = (msg.message_type or "TEXT").upper()
    if not body:
        if mt == "IMAGE":
            return "📷 Photo"
        if mt == "VOICE":
            return "🎤 Voice message"
        if mt == "DOCUMENT":
            return "📄 Document"
        return "Message"
    if mt == "VOICE" and ("voice note" in body.lower() or body.startswith("🎤")):
        return "🎤 Voice message"
    if mt == "DOCUMENT" and (body.startswith("📄") or body.lower().endswith(".pdf")):
        # Prefer generic label when it's just the default / filename
        if body in {"📄 Document", "📄"} or body.lower().endswith(".pdf"):
            return "📄 Document"
    return body[:120]


def reaction_preview_text(
    *,
    reactor_is_me: bool,
    reactor_name: str,
    emoji: str,
    message_body: str | None,
) -> str:
    snip = snippet_for_reaction(message_body)
    if reactor_is_me:
        return f'You reacted {emoji} to "{snip}"'
    name = (reactor_name or "Someone").strip() or "Someone"
    return f'{name} reacted {emoji} to "{snip}"'
