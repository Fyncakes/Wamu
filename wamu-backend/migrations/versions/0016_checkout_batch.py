"""0016 — multi-shop checkout batch ids on orders and deliveries."""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

from migrations.helpers import column_exists, table_exists

revision = "0016_checkout_batch"
down_revision = "0015_device_link"
branch_labels = None
depends_on = None


def upgrade() -> None:
    if table_exists("orders") and not column_exists("orders", "checkout_batch_id"):
        op.add_column(
            "orders",
            sa.Column("checkout_batch_id", sa.Uuid(), nullable=True),
        )
        op.create_index(
            "ix_orders_checkout_batch_id",
            "orders",
            ["checkout_batch_id"],
        )
    if table_exists("deliveries") and not column_exists("deliveries", "delivery_batch_id"):
        op.add_column(
            "deliveries",
            sa.Column("delivery_batch_id", sa.Uuid(), nullable=True),
        )
        op.create_index(
            "ix_deliveries_delivery_batch_id",
            "deliveries",
            ["delivery_batch_id"],
        )


def downgrade() -> None:
    if table_exists("deliveries") and column_exists("deliveries", "delivery_batch_id"):
        op.drop_index("ix_deliveries_delivery_batch_id", table_name="deliveries")
        op.drop_column("deliveries", "delivery_batch_id")
    if table_exists("orders") and column_exists("orders", "checkout_batch_id"):
        op.drop_index("ix_orders_checkout_batch_id", table_name="orders")
        op.drop_column("orders", "checkout_batch_id")
