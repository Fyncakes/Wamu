"""Inbox preview string helpers."""

from __future__ import annotations

from types import SimpleNamespace

from app.services.inbox_preview import (
    message_preview_text,
    reaction_preview_text,
    snippet_for_reaction,
)


def test_snippet_strips_media_prefix():
    assert snippet_for_reaction("📷 Photo") == "Photo"
    assert snippet_for_reaction("Hello Kampala") == "Hello Kampala"
    assert "…" in snippet_for_reaction("x" * 80)


def test_message_preview_normalizes_voice_and_data_saver():
    msg = SimpleNamespace(body="🎤 Voice note", message_type="VOICE")
    assert message_preview_text(msg) == "🎤 Voice message"
    msg2 = SimpleNamespace(body="📷 Photo (data saver)", message_type="IMAGE")
    assert message_preview_text(msg2) == "📷 Photo"


def test_reaction_preview_you_and_peer():
    assert (
        reaction_preview_text(
            reactor_is_me=True,
            reactor_name="Me",
            emoji="👍",
            message_body="Hello",
        )
        == 'You reacted 👍 to "Hello"'
    )
    assert (
        reaction_preview_text(
            reactor_is_me=False,
            reactor_name="Amina",
            emoji="😂",
            message_body="📷 Photo",
        )
        == 'Amina reacted 😂 to "Photo"'
    )
