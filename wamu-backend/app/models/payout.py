"""
Merchant payouts — non-custodial MoMo disbursements to business payee MSISDN.

Wamu never holds a merchant balance. After customer collection SUCCESS, we
instruct the licensed provider to transfer to the business payout phone.
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
