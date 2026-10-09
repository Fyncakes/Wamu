"""
Payments — immutable financial records after SUCCESS.

Never PATCH successful payments. Idempotency via provider_reference + user idempotency_key.
"""

from __future__ import annotations

import enum
import uuid
from datetime import datetime
from decimal import Decimal

from sqlalchemy import (
    JSON,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Numeric,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base
from app.models.mixins import TimestampMixin, UUIDMixin


class PaymentStatus(str, enum.Enum):
    PENDING = "PENDING"
    PROCESSING = "PROCESSING"
    SUCCESS = "SUCCESS"
    FAILED = "FAILED"
    REFUNDED = "REFUNDED"


class PaymentProvider(str, enum.Enum):
    MOCK = "MOCK"
    MTN = "MTN"
    AIRTEL = "AIRTEL"
    CARD = "CARD"


class Payment(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "payments"
    __table_args__ = (
        CheckConstraint("amount > 0", name="payments_amount_positive"),
        CheckConstraint("currency = 'UGX'", name="payments_currency_ugx"),
        UniqueConstraint("provider", "provider_reference", name="uq_payment_provider_reference"),
        UniqueConstraint("user_id", "idempotency_key", name="uq_payment_idempotency"),
    )

    order_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("orders.id"), unique=True, nullable=False
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id"), nullable=False, index=True
    )
    amount: Mapped[Decimal] = mapped_column(Numeric(14, 2), nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="UGX")
    provider: Mapped[str] = mapped_column(
        String(20), nullable=False, default=PaymentProvider.MOCK.value
    )
    provider_reference: Mapped[str | None] = mapped_column(String(100))
    idempotency_key: Mapped[str] = mapped_column(String(100), nullable=False)
    status: Mapped[str] = mapped_column(
        String(20), nullable=False, default=PaymentStatus.PENDING.value, index=True
    )
    phone: Mapped[str | None] = mapped_column(String(20))
    raw_response: Mapped[dict | None] = mapped_column(JSON)

    order = relationship("Order", back_populates="payment")


class PaymentWebhookEvent(UUIDMixin, Base):
    """Deduplicate provider webhooks so each event is processed at most once."""

    __tablename__ = "payment_webhook_events"
    __table_args__ = (
        UniqueConstraint("provider", "event_id", name="uq_webhook_provider_event"),
    )

    provider: Mapped[str] = mapped_column(String(20), nullable=False)
    event_id: Mapped[str] = mapped_column(String(150), nullable=False)
    payload: Mapped[dict] = mapped_column(JSON, nullable=False)
    processed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    notes: Mapped[str | None] = mapped_column(Text)
