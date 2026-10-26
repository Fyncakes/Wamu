"""Receipt timestamps only move forward and stay idempotent."""

from datetime import datetime, timezone
from uuid import uuid4

from app.models.chat import Message
from app.services.chat import _advance_receipt, push_label_for_message


def _msg(status: str = "SENT") -> Message:
    return Message(
        conversation_id=uuid4(),
        sender_id=uuid4(),
        body="hi",
        status=status,
    )


def test_sent_to_read_stamps_both_times_once():
    msg = _msg()
    assert _advance_receipt(msg, "READ") is True
    assert msg.status == "READ"
    assert msg.delivered_at is not None
    assert msg.read_at == msg.delivered_at
    first = msg.delivered_at
    assert _advance_receipt(msg, "READ") is False
    assert msg.delivered_at == first
    assert msg.read_at == first


def test_delivered_then_read_keeps_the_first_delivery_time():
    msg = _msg()
    earlier = datetime(2026, 1, 1, tzinfo=timezone.utc)
    later = datetime(2026, 1, 2, tzinfo=timezone.utc)
    _advance_receipt(msg, "DELIVERED", now=earlier)
    _advance_receipt(msg, "READ", now=later)
    assert msg.delivered_at == earlier
    assert msg.read_at == later
    assert msg.status == "READ"


def test_push_labels_stay_generic():
    assert push_label_for_message("IMAGE") == "Photo"
    assert push_label_for_message("VOICE") == "Voice message"
    assert push_label_for_message("TEXT") == "New message"
    assert push_label_for_message(None) == "New message"
