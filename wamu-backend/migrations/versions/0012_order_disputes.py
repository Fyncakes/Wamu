"""0012 — order_disputes table for commerce dispute queue."""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

from migrations.helpers import table_exists

revision = "0012_order_disputes"
down_revision = "0011_proof_of_delivery"
branch_labels = None
depends_on = None


def upgrade() -> None:
    if table_exists("order_disputes"):
        return
    op.create_table(
        "order_disputes",
        sa.Column("id", sa.Uuid(), primary_key=True, nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("CURRENT_TIMESTAMP"),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("CURRENT_TIMESTAMP"),
            nullable=False,
        ),
        sa.Column("order_id", sa.Uuid(), sa.ForeignKey("orders.id"), nullable=False),
        sa.Column("customer_id", sa.Uuid(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("reason", sa.String(100), nullable=False),
        sa.Column("description", sa.Text(), nullable=True),
        sa.Column("status", sa.String(30), nullable=False, server_default="OPEN"),
        sa.Column("resolution_note", sa.Text(), nullable=True),
        sa.Column("resolved_by_id", sa.Uuid(), sa.ForeignKey("users.id"), nullable=True),
        sa.Column("resolved_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_order_disputes_order_id", "order_disputes", ["order_id"])
    op.create_index("ix_order_disputes_customer_id", "order_disputes", ["customer_id"])
    op.create_index("ix_order_disputes_status", "order_disputes", ["status"])


def downgrade() -> None:
    if table_exists("order_disputes"):
        op.drop_table("order_disputes")
