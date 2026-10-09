"""Order disputes — customer opens, admin resolves (Master Plan P0 thin MVP)."""

from __future__ import annotations

import enum
import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, String, Text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base
from app.models.mixins import TimestampMixin, UUIDMixin


class DisputeStatus(str, enum.Enum):
    OPEN = "OPEN"
    RESOLVED_REFUND = "RESOLVED_REFUND"
    RESOLVED_REJECT = "RESOLVED_REJECT"
    DISMISSED = "DISMISSED"


class DisputeReason(str, enum.Enum):
    NOT_DELIVERED = "NOT_DELIVERED"
    WRONG_ITEMS = "WRONG_ITEMS"
    QUALITY = "QUALITY"
    OTHER = "OTHER"


class OrderDispute(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "order_disputes"

    order_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("orders.id"), nullable=False, index=True
    )
    customer_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id"), nullable=False, index=True
    )
    reason: Mapped[str] = mapped_column(String(100), nullable=False)
    description: Mapped[str | None] = mapped_column(Text)
    status: Mapped[str] = mapped_column(
        String(30), nullable=False, default=DisputeStatus.OPEN.value, index=True
    )
    resolution_note: Mapped[str | None] = mapped_column(Text)
    resolved_by_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id"), nullable=True
    )
    resolved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
