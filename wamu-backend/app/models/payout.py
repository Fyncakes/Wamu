"""
Non-custodial MoMo disbursements — merchant, rider, and owner commission.

Wamu never holds a wallet balance. After collection SUCCESS / delivery DONE /
admin commission withdraw, we instruct the licensed provider to transfer.
"""

from __future__ import annotations

import enum
import uuid
from decimal import Decimal

from sqlalchemy import (
    JSON,
    CheckConstraint,
    ForeignKey,
    Integer,
    Numeric,
    String,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base
from app.models.mixins import TimestampMixin, UUIDMixin


class PayoutStatus(str, enum.Enum):
    PENDING = "PENDING"
    PROCESSING = "PROCESSING"
    SUCCESS = "SUCCESS"
    FAILED = "FAILED"
    REVERSED = "REVERSED"


class MerchantPayout(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "merchant_payouts"
    __table_args__ = (
        CheckConstraint("amount > 0", name="merchant_payouts_amount_positive"),
        CheckConstraint("platform_fee >= 0", name="merchant_payouts_fee_nonneg"),
        CheckConstraint("currency = 'UGX'", name="merchant_payouts_currency_ugx"),
        UniqueConstraint("payment_id", name="uq_merchant_payout_payment"),
        UniqueConstraint(
            "provider", "provider_reference", name="uq_merchant_payout_provider_ref"
        ),
        UniqueConstraint(
            "business_id", "idempotency_key", name="uq_merchant_payout_idempotency"
        ),
    )

    payment_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("payments.id"), nullable=False, index=True
    )
    order_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("orders.id"), nullable=False, index=True
    )
    business_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("businesses.id"), nullable=False, index=True
    )
    amount: Mapped[Decimal] = mapped_column(Numeric(14, 2), nullable=False)
    # Non-custodial fee: retained in MoMo float; never credited to a Wamu wallet.
    platform_fee: Mapped[Decimal] = mapped_column(
        Numeric(14, 2), nullable=False, default=Decimal("0.00")
    )
    fee_bps: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="UGX")
    provider: Mapped[str] = mapped_column(String(20), nullable=False)
    provider_reference: Mapped[str | None] = mapped_column(String(100))
    idempotency_key: Mapped[str] = mapped_column(String(100), nullable=False)
    payee_phone: Mapped[str] = mapped_column(String(20), nullable=False)
    status: Mapped[str] = mapped_column(
        String(20), nullable=False, default=PayoutStatus.PENDING.value, index=True
    )
    raw_response: Mapped[dict | None] = mapped_column(JSON)

    payment = relationship("Payment", backref="merchant_payout", uselist=False)


class RiderPayout(UUIDMixin, TimestampMixin, Base):
    """Delivery fee disbursement to rider MSISDN after DELIVERED."""

    __tablename__ = "rider_payouts"
    __table_args__ = (
        CheckConstraint("amount > 0", name="rider_payouts_amount_positive"),
        CheckConstraint("currency = 'UGX'", name="rider_payouts_currency_ugx"),
        UniqueConstraint("delivery_id", name="uq_rider_payout_delivery"),
        UniqueConstraint(
            "provider", "provider_reference", name="uq_rider_payout_provider_ref"
        ),
        UniqueConstraint(
            "rider_id", "idempotency_key", name="uq_rider_payout_idempotency"
        ),
    )

    delivery_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("deliveries.id"), nullable=False, index=True
    )
    order_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("orders.id"), nullable=False, index=True
    )
    rider_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("rider_profiles.id"), nullable=False, index=True
    )
    amount: Mapped[Decimal] = mapped_column(Numeric(14, 2), nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="UGX")
    provider: Mapped[str] = mapped_column(String(20), nullable=False)
    provider_reference: Mapped[str | None] = mapped_column(String(100))
    idempotency_key: Mapped[str] = mapped_column(String(100), nullable=False)
    payee_phone: Mapped[str] = mapped_column(String(20), nullable=False)
    status: Mapped[str] = mapped_column(
        String(20), nullable=False, default=PayoutStatus.PENDING.value, index=True
    )
    raw_response: Mapped[dict | None] = mapped_column(JSON)


class OwnerPayout(UUIDMixin, TimestampMixin, Base):
    """Platform commission withdrawal to Wamu owner MoMo (admin-initiated)."""

    __tablename__ = "owner_payouts"
    __table_args__ = (
        CheckConstraint("amount > 0", name="owner_payouts_amount_positive"),
        CheckConstraint("currency = 'UGX'", name="owner_payouts_currency_ugx"),
        UniqueConstraint(
            "provider", "provider_reference", name="uq_owner_payout_provider_ref"
        ),
        UniqueConstraint("idempotency_key", name="uq_owner_payout_idempotency"),
    )

    amount: Mapped[Decimal] = mapped_column(Numeric(14, 2), nullable=False)
    amount_minor: Mapped[int] = mapped_column(Integer, nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="UGX")
    provider: Mapped[str] = mapped_column(String(20), nullable=False)
    provider_reference: Mapped[str | None] = mapped_column(String(100))
    idempotency_key: Mapped[str] = mapped_column(String(100), nullable=False)
    payee_phone: Mapped[str] = mapped_column(String(20), nullable=False)
    status: Mapped[str] = mapped_column(
        String(20), nullable=False, default=PayoutStatus.PENDING.value, index=True
    )
    requested_by: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id"), nullable=True
    )
    notes: Mapped[str | None] = mapped_column(String(500))
    raw_response: Mapped[dict | None] = mapped_column(JSON)
