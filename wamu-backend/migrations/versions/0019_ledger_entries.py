"""0019 — immutable double-entry ledger_entries."""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

from migrations.helpers import index_exists, table_exists

revision = "0019_ledger_entries"
down_revision = "0018_payment_otp"
branch_labels = None
depends_on = None


def upgrade() -> None:
    if table_exists("ledger_entries"):
        return
    op.create_table(
        "ledger_entries",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("entry_group_id", UUID(as_uuid=True), nullable=False),
        sa.Column("account_type", sa.String(40), nullable=False),
        sa.Column("account_id", UUID(as_uuid=True), nullable=True),
        sa.Column("direction", sa.String(10), nullable=False),
        sa.Column("amount_minor", sa.BigInteger(), nullable=False),
        sa.Column("currency", sa.String(3), nullable=False, server_default="UGX"),
        sa.Column("source_type", sa.String(30), nullable=False),
        sa.Column("source_id", UUID(as_uuid=True), nullable=False),
        sa.Column("idempotency_key", sa.String(200), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("CURRENT_TIMESTAMP"),
            nullable=False,
        ),
        sa.Column("created_by", sa.String(80), nullable=False, server_default="system"),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.CheckConstraint("amount_minor >= 0", name="ledger_amount_nonneg"),
        sa.CheckConstraint(
            "direction IN ('DEBIT', 'CREDIT')", name="ledger_direction_valid"
        ),
        sa.UniqueConstraint("idempotency_key", name="uq_ledger_idempotency"),
    )
    if not index_exists("ledger_entries", "ix_ledger_account"):
        op.create_index(
            "ix_ledger_account", "ledger_entries", ["account_type", "account_id"]
        )
    if not index_exists("ledger_entries", "ix_ledger_source"):
        op.create_index(
            "ix_ledger_source", "ledger_entries", ["source_type", "source_id"]
        )
    if not index_exists("ledger_entries", "ix_ledger_entry_group"):
        op.create_index("ix_ledger_entry_group", "ledger_entries", ["entry_group_id"])
    if not index_exists("ledger_entries", "ix_ledger_entries_entry_group_id"):
        # SQLAlchemy also may emit entry_group_id index via mapped index=True
        pass


def downgrade() -> None:
    if table_exists("ledger_entries"):
        op.drop_table("ledger_entries")
