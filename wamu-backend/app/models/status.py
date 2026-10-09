"""24-hour Status / Stories — Uganda youth engagement surface."""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, String, Text, func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base
from app.models.mixins import UUIDMixin


class StatusUpdate(UUIDMixin, Base):
    __tablename__ = "status_updates"

    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    # TEXT | IMAGE | VOICE
    media_type: Mapped[str] = mapped_column(String(20), nullable=False, default="TEXT")
    body: Mapped[str | None] = mapped_column(Text)
    media_url: Mapped[str | None] = mapped_column(Text)
    background_color: Mapped[str | None] = mapped_column(String(20), default="#0B6E4F")
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False, index=True
    )
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, index=True)
    # EVERYONE | CONTACTS (default CONTACTS — no global status leak)
    audience: Mapped[str] = mapped_column(String(20), nullable=False, default="CONTACTS")
