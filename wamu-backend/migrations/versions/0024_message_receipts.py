"""0024 — message delivered_at / read_at for truthful chat receipts."""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

from migrations.helpers import column_exists, table_exists

revision = "0024_message_receipts"
down_revision = "0023_delivery_fare"
branch_labels = None
depends_on = None


def upgrade() -> None:
    if not table_exists("messages"):
        return
    if not column_exists("messages", "delivered_at"):
        op.add_column("messages", sa.Column("delivered_at", sa.DateTime(timezone=True), nullable=True))
    if not column_exists("messages", "read_at"):
        op.add_column("messages", sa.Column("read_at", sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    if not table_exists("messages"):
        return
    if column_exists("messages", "read_at"):
        op.drop_column("messages", "read_at")
    if column_exists("messages", "delivered_at"):
        op.drop_column("messages", "delivered_at")
