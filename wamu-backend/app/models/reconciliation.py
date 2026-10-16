"""Phase B — provider statement lines, reconciliation runs, suspense queue."""

from __future__ import annotations

import enum
import uuid
from datetime import datetime

from sqlalchemy import (
    BigInteger,
    DateTime,
    ForeignKey,
    Index,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import JSON, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base
from app.models.mixins import UUIDMixin


class StatementMatchStatus(str, enum.Enum):
    UNMATCHED = "UNMATCHED"
    MATCHED = "MATCHED"
    SUSPENSE = "SUSPENSE"
    IGNORED = "IGNORED"


class SuspenseStatus(str, enum.Enum):
    OPEN = "OPEN"
    RESOLVED = "RESOLVED"


class ReconciliationRunStatus(str, enum.Enum):
    RUNNING = "RUNNING"
    COMPLETED = "COMPLETED"
    FAILED = "FAILED"


class ProviderStatementBatch(UUIDMixin, Base):
    __tablename__ = "provider_statement_batches"

    provider: Mapped[str] = mapped_column(String(20), nullable=False, index=True)
    source: Mapped[str] = mapped_column(
        String(40), nullable=False, default="synthetic"
    )  # synthetic | import | api
    period_start: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    period_end: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    status: Mapped[str] = mapped_column(
        String(20), nullable=False, default=ReconciliationRunStatus.COMPLETED.value
    )
    notes: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    created_by: Mapped[str] = mapped_column(String(80), nullable=False, default="system")


class ProviderStatementLine(UUIDMixin, Base):
    __tablename__ = "provider_statement_lines"
    __table_args__ = (
        UniqueConstraint("batch_id", "external_ref", name="uq_statement_line_ref"),
        Index("ix_statement_line_match", "match_status", "provider"),
    )

    batch_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("provider_statement_batches.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    provider: Mapped[str] = mapped_column(String(20), nullable=False)
    external_ref: Mapped[str] = mapped_column(String(150), nullable=False)
    amount_minor: Mapped[int] = mapped_column(BigInteger, nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="UGX")
    occurred_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    raw: Mapped[dict | None] = mapped_column(JSON)
    match_status: Mapped[str] = mapped_column(
        String(20), nullable=False, default=StatementMatchStatus.UNMATCHED.value, index=True
    )
    matched_payment_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("payments.id"), nullable=True
    )
    matched_payout_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("merchant_payouts.id"), nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class SuspenseItem(UUIDMixin, Base):
    __tablename__ = "suspense_items"

    statement_line_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("provider_statement_lines.id", ondelete="CASCADE"),
        nullable=False,
        unique=True,
    )
    provider: Mapped[str] = mapped_column(String(20), nullable=False)
    amount_minor: Mapped[int] = mapped_column(BigInteger, nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="UGX")
    reason: Mapped[str] = mapped_column(String(200), nullable=False)
    status: Mapped[str] = mapped_column(
        String(20), nullable=False, default=SuspenseStatus.OPEN.value, index=True
    )
    ledger_group_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True))
    resolved_by: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id"), nullable=True
    )
    resolved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    resolution_notes: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class ReconciliationRun(UUIDMixin, Base):
    __tablename__ = "reconciliation_runs"

    provider: Mapped[str] = mapped_column(String(20), nullable=False, index=True)
    batch_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("provider_statement_batches.id"), nullable=True
    )
    status: Mapped[str] = mapped_column(
        String(20), nullable=False, default=ReconciliationRunStatus.RUNNING.value
    )
    lines_total: Mapped[int] = mapped_column(default=0, nullable=False)
    matched: Mapped[int] = mapped_column(default=0, nullable=False)
    unmatched: Mapped[int] = mapped_column(default=0, nullable=False)
    suspense: Mapped[int] = mapped_column(default=0, nullable=False)
    summary: Mapped[dict | None] = mapped_column(JSON)
    started_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_by: Mapped[str] = mapped_column(String(80), nullable=False, default="system")
