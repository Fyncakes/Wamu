"""0023 — delivery fare snapshots + fare offers + rider pricing prefs."""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

from migrations.helpers import column_exists, table_exists

revision = "0023_delivery_fare"
down_revision = "0022_merchant_kyc"
branch_labels = None
depends_on = None


def upgrade() -> None:
    if table_exists("deliveries"):
        cols = [
            ("distance_km", sa.Column("distance_km", sa.Numeric(10, 3), nullable=True)),
            ("estimated_fee", sa.Column("estimated_fee", sa.Numeric(14, 2), nullable=True)),
            ("agreed_fee", sa.Column("agreed_fee", sa.Numeric(14, 2), nullable=True)),
            (
                "fare_rule_snapshot",
                sa.Column("fare_rule_snapshot", sa.JSON(), nullable=True),
            ),
        ]
        for name, col in cols:
            if not column_exists("deliveries", name):
                op.add_column("deliveries", col)

    if table_exists("rider_profiles") and not column_exists(
        "rider_profiles", "preferred_min_per_km_ugx"
    ):
        op.add_column(
            "rider_profiles",
            sa.Column("preferred_min_per_km_ugx", sa.Numeric(14, 2), nullable=True),
        )

    if not table_exists("delivery_fare_offers"):
        op.create_table(
            "delivery_fare_offers",
            sa.Column("id", UUID(as_uuid=True), primary_key=True),
            sa.Column(
                "delivery_id",
                UUID(as_uuid=True),
                sa.ForeignKey("deliveries.id"),
                nullable=False,
                index=True,
            ),
            sa.Column(
                "order_id",
                UUID(as_uuid=True),
                sa.ForeignKey("orders.id"),
                nullable=False,
                index=True,
            ),
            sa.Column(
                "rider_id",
                UUID(as_uuid=True),
                sa.ForeignKey("rider_profiles.id"),
                nullable=False,
                index=True,
            ),
            sa.Column("proposed_fee", sa.Numeric(14, 2), nullable=False),
            sa.Column("original_fee", sa.Numeric(14, 2), nullable=False),
            sa.Column("currency", sa.String(3), nullable=False, server_default="UGX"),
            sa.Column("reason", sa.Text(), nullable=True),
            sa.Column(
                "status",
                sa.String(20),
                nullable=False,
                server_default="PENDING",
            ),
            sa.Column("distance_km", sa.Numeric(10, 3), nullable=True),
            sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
            sa.Column("resolved_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column(
                "resolved_by_id",
                UUID(as_uuid=True),
                sa.ForeignKey("users.id"),
                nullable=True,
            ),
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
        )


def downgrade() -> None:
    if table_exists("delivery_fare_offers"):
        op.drop_table("delivery_fare_offers")
    if table_exists("rider_profiles") and column_exists(
        "rider_profiles", "preferred_min_per_km_ugx"
    ):
        op.drop_column("rider_profiles", "preferred_min_per_km_ugx")
    if table_exists("deliveries"):
        for name in ("fare_rule_snapshot", "agreed_fee", "estimated_fee", "distance_km"):
            if column_exists("deliveries", name):
                op.drop_column("deliveries", name)
