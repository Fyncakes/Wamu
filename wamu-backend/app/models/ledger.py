"""Immutable double-entry ledger — balances are derived, never stored."""

from __future__ import annotations

import enum
import uuid
from datetime import datetime

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base
from app.models.mixins import UUIDMixin


class LedgerDirection(str, enum.Enum):
    DEBIT = "DEBIT"
    CREDIT = "CREDIT"


class LedgerAccountType(str, enum.Enum):
    CUSTOMER_RECEIVABLE = "customer_receivable"
    PROVIDER_CLEARING = "provider_clearing"
    MERCHANT_PAYABLE = "merchant_payable"
    RIDER_PAYABLE = "rider_payable"
    WAMU_COMMISSION = "wamu_commission"
    WAMU_PROVIDER_FEES = "wamu_provider_fees"
    WAMU_OWNER_PAYOUT = "wamu_owner_payout"
    REFUNDS_PAYABLE = "refunds_payable"
    SUSPENSE = "suspense"


class LedgerSourceType(str, enum.Enum):
    ORDER = "order"
    REFUND = "refund"
    PAYOUT = "payout"
    ADJUSTMENT = "adjustment"


class LedgerEntry(UUIDMixin, Base):
    """One leg of a balanced entry group. Never UPDATE amount/direction after insert."""

    __tablename__ = "ledger_entries"
    __table_args__ = (
        CheckConstraint("amount_minor >= 0", name="ledger_amount_nonneg"),
        CheckConstraint(
            "direction IN ('DEBIT', 'CREDIT')", name="ledger_direction_valid"
        ),
        UniqueConstraint("idempotency_key", name="uq_ledger_idempotency"),
        Index("ix_ledger_account", "account_type", "account_id"),
        Index("ix_ledger_source", "source_type", "source_id"),
        Index("ix_ledger_entry_group", "entry_group_id"),
    )

    entry_group_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), nullable=False, index=True
    )
    account_type: Mapped[str] = mapped_column(String(40), nullable=False)
    account_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), nullable=True
    )
    direction: Mapped[str] = mapped_column(String(10), nullable=False)
    amount_minor: Mapped[int] = mapped_column(BigInteger, nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="UGX")
    source_type: Mapped[str] = mapped_column(String(30), nullable=False)
    source_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    idempotency_key: Mapped[str] = mapped_column(String(200), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    created_by: Mapped[str] = mapped_column(String(80), nullable=False, default="system")
    notes: Mapped[str | None] = mapped_column(Text)
