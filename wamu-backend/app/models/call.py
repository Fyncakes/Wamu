"""1:1 call sessions — history + signaling metadata (media is peer WebRTC)."""

from __future__ import annotations

import enum
import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, String, func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base
from app.models.mixins import UUIDMixin


class CallType(str, enum.Enum):
    VOICE = "VOICE"
    VIDEO = "VIDEO"


class CallStatus(str, enum.Enum):
    RINGING = "RINGING"
    ACCEPTED = "ACCEPTED"
    REJECTED = "REJECTED"
    ENDED = "ENDED"
    MISSED = "MISSED"
    CANCELLED = "CANCELLED"


class CallSession(UUIDMixin, Base):
    __tablename__ = "call_sessions"

    caller_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id"), nullable=False, index=True
    )
    callee_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id"), nullable=False, index=True
    )
    conversation_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("conversations.id"), nullable=True, index=True
    )
    call_type: Mapped[str] = mapped_column(String(20), nullable=False, default=CallType.VOICE.value)
    status: Mapped[str] = mapped_column(String(20), nullable=False, default=CallStatus.RINGING.value)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False, index=True
    )
    answered_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
