"""0020 — provider statements, reconciliation runs, suspense items."""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSON, UUID

from migrations.helpers import index_exists, table_exists

revision = "0020_reconciliation"
down_revision = "0019_ledger_entries"
branch_labels = None
depends_on = None


def upgrade() -> None:
    if not table_exists("provider_statement_batches"):
        op.create_table(
            "provider_statement_batches",
            sa.Column("id", UUID(as_uuid=True), primary_key=True),
            sa.Column("provider", sa.String(20), nullable=False),
            sa.Column("source", sa.String(40), nullable=False, server_default="synthetic"),
            sa.Column("period_start", sa.DateTime(timezone=True), nullable=True),
            sa.Column("period_end", sa.DateTime(timezone=True), nullable=True),
            sa.Column("status", sa.String(20), nullable=False, server_default="COMPLETED"),
            sa.Column("notes", sa.Text(), nullable=True),
            sa.Column(
                "created_at",
                sa.DateTime(timezone=True),
                server_default=sa.text("CURRENT_TIMESTAMP"),
                nullable=False,
            ),
            sa.Column("created_by", sa.String(80), nullable=False, server_default="system"),
        )
        op.create_index(
            "ix_provider_statement_batches_provider",
            "provider_statement_batches",
            ["provider"],
        )

    if not table_exists("provider_statement_lines"):
        op.create_table(
            "provider_statement_lines",
            sa.Column("id", UUID(as_uuid=True), primary_key=True),
            sa.Column(
                "batch_id",
                UUID(as_uuid=True),
                sa.ForeignKey("provider_statement_batches.id", ondelete="CASCADE"),
                nullable=False,
            ),
            sa.Column("provider", sa.String(20), nullable=False),
            sa.Column("external_ref", sa.String(150), nullable=False),
            sa.Column("amount_minor", sa.BigInteger(), nullable=False),
            sa.Column("currency", sa.String(3), nullable=False, server_default="UGX"),
            sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("raw", JSON(), nullable=True),
            sa.Column("match_status", sa.String(20), nullable=False, server_default="UNMATCHED"),
            sa.Column(
                "matched_payment_id",
                UUID(as_uuid=True),
                sa.ForeignKey("payments.id"),
                nullable=True,
            ),
            sa.Column(
                "matched_payout_id",
                UUID(as_uuid=True),
                sa.ForeignKey("merchant_payouts.id"),
                nullable=True,
            ),
            sa.Column(
                "created_at",
                sa.DateTime(timezone=True),
                server_default=sa.text("CURRENT_TIMESTAMP"),
                nullable=False,
            ),
            sa.UniqueConstraint("batch_id", "external_ref", name="uq_statement_line_ref"),
        )
        op.create_index(
            "ix_provider_statement_lines_batch_id",
            "provider_statement_lines",
            ["batch_id"],
        )
        if not index_exists("provider_statement_lines", "ix_statement_line_match"):
            op.create_index(
                "ix_statement_line_match",
                "provider_statement_lines",
                ["match_status", "provider"],
            )

    if not table_exists("suspense_items"):
        op.create_table(
            "suspense_items",
            sa.Column("id", UUID(as_uuid=True), primary_key=True),
            sa.Column(
                "statement_line_id",
                UUID(as_uuid=True),
                sa.ForeignKey("provider_statement_lines.id", ondelete="CASCADE"),
                nullable=False,
                unique=True,
            ),
            sa.Column("provider", sa.String(20), nullable=False),
            sa.Column("amount_minor", sa.BigInteger(), nullable=False),
            sa.Column("currency", sa.String(3), nullable=False, server_default="UGX"),
            sa.Column("reason", sa.String(200), nullable=False),
            sa.Column("status", sa.String(20), nullable=False, server_default="OPEN"),
            sa.Column("ledger_group_id", UUID(as_uuid=True), nullable=True),
            sa.Column(
                "resolved_by",
                UUID(as_uuid=True),
                sa.ForeignKey("users.id"),
                nullable=True,
            ),
            sa.Column("resolved_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("resolution_notes", sa.Text(), nullable=True),
            sa.Column(
                "created_at",
                sa.DateTime(timezone=True),
                server_default=sa.text("CURRENT_TIMESTAMP"),
                nullable=False,
            ),
        )
        op.create_index("ix_suspense_items_status", "suspense_items", ["status"])

    if not table_exists("reconciliation_runs"):
        op.create_table(
            "reconciliation_runs",
            sa.Column("id", UUID(as_uuid=True), primary_key=True),
            sa.Column("provider", sa.String(20), nullable=False),
            sa.Column(
                "batch_id",
                UUID(as_uuid=True),
                sa.ForeignKey("provider_statement_batches.id"),
                nullable=True,
            ),
            sa.Column("status", sa.String(20), nullable=False, server_default="RUNNING"),
            sa.Column("lines_total", sa.Integer(), nullable=False, server_default="0"),
            sa.Column("matched", sa.Integer(), nullable=False, server_default="0"),
            sa.Column("unmatched", sa.Integer(), nullable=False, server_default="0"),
            sa.Column("suspense", sa.Integer(), nullable=False, server_default="0"),
            sa.Column("summary", JSON(), nullable=True),
            sa.Column(
                "started_at",
                sa.DateTime(timezone=True),
                server_default=sa.text("CURRENT_TIMESTAMP"),
                nullable=False,
            ),
            sa.Column("finished_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("created_by", sa.String(80), nullable=False, server_default="system"),
        )
        op.create_index(
            "ix_reconciliation_runs_provider", "reconciliation_runs", ["provider"]
        )


def downgrade() -> None:
    for name in (
        "reconciliation_runs",
        "suspense_items",
        "provider_statement_lines",
        "provider_statement_batches",
    ):
        if table_exists(name):
            op.drop_table(name)
