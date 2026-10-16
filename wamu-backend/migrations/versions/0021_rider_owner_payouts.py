"""0021 — rider/owner payouts + rider payout destination fields."""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

from migrations.helpers import column_exists, table_exists

revision = "0021_rider_owner_payouts"
down_revision = "0020_reconciliation"
branch_labels = None
depends_on = None


def upgrade() -> None:
    if table_exists("rider_profiles"):
        if not column_exists("rider_profiles", "payout_phone"):
            op.add_column(
                "rider_profiles", sa.Column("payout_phone", sa.String(20), nullable=True)
            )
        if not column_exists("rider_profiles", "payout_provider"):
            op.add_column(
                "rider_profiles",
                sa.Column("payout_provider", sa.String(20), nullable=True),
            )

    if not table_exists("rider_payouts"):
        op.create_table(
            "rider_payouts",
            sa.Column("id", UUID(as_uuid=True), primary_key=True),
            sa.Column(
                "delivery_id",
                UUID(as_uuid=True),
                sa.ForeignKey("deliveries.id"),
                nullable=False,
            ),
            sa.Column(
                "order_id",
                UUID(as_uuid=True),
                sa.ForeignKey("orders.id"),
                nullable=False,
            ),
            sa.Column(
                "rider_id",
                UUID(as_uuid=True),
                sa.ForeignKey("rider_profiles.id"),
                nullable=False,
            ),
            sa.Column("amount", sa.Numeric(14, 2), nullable=False),
            sa.Column("currency", sa.String(3), nullable=False, server_default="UGX"),
            sa.Column("provider", sa.String(20), nullable=False),
            sa.Column("provider_reference", sa.String(100), nullable=True),
            sa.Column("idempotency_key", sa.String(100), nullable=False),
            sa.Column("payee_phone", sa.String(20), nullable=False),
            sa.Column("status", sa.String(20), nullable=False, server_default="PENDING"),
            sa.Column("raw_response", sa.JSON(), nullable=True),
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
            sa.UniqueConstraint("delivery_id", name="uq_rider_payout_delivery"),
            sa.UniqueConstraint(
                "provider", "provider_reference", name="uq_rider_payout_provider_ref"
            ),
            sa.UniqueConstraint(
                "rider_id", "idempotency_key", name="uq_rider_payout_idempotency"
            ),
            sa.CheckConstraint("amount > 0", name="rider_payouts_amount_positive"),
            sa.CheckConstraint("currency = 'UGX'", name="rider_payouts_currency_ugx"),
        )
        op.create_index("ix_rider_payouts_status", "rider_payouts", ["status"])
        op.create_index("ix_rider_payouts_rider_id", "rider_payouts", ["rider_id"])

    if not table_exists("owner_payouts"):
        op.create_table(
            "owner_payouts",
            sa.Column("id", UUID(as_uuid=True), primary_key=True),
            sa.Column("amount", sa.Numeric(14, 2), nullable=False),
            sa.Column("amount_minor", sa.Integer(), nullable=False),
            sa.Column("currency", sa.String(3), nullable=False, server_default="UGX"),
            sa.Column("provider", sa.String(20), nullable=False),
            sa.Column("provider_reference", sa.String(100), nullable=True),
            sa.Column("idempotency_key", sa.String(100), nullable=False),
            sa.Column("payee_phone", sa.String(20), nullable=False),
            sa.Column("status", sa.String(20), nullable=False, server_default="PENDING"),
            sa.Column(
                "requested_by",
                UUID(as_uuid=True),
                sa.ForeignKey("users.id"),
                nullable=True,
            ),
            sa.Column("notes", sa.String(500), nullable=True),
            sa.Column("raw_response", sa.JSON(), nullable=True),
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
            sa.UniqueConstraint(
                "provider", "provider_reference", name="uq_owner_payout_provider_ref"
            ),
            sa.UniqueConstraint("idempotency_key", name="uq_owner_payout_idempotency"),
            sa.CheckConstraint("amount > 0", name="owner_payouts_amount_positive"),
            sa.CheckConstraint("currency = 'UGX'", name="owner_payouts_currency_ugx"),
        )
        op.create_index("ix_owner_payouts_status", "owner_payouts", ["status"])


def downgrade() -> None:
    if table_exists("owner_payouts"):
        op.drop_table("owner_payouts")
    if table_exists("rider_payouts"):
        op.drop_table("rider_payouts")
    if table_exists("rider_profiles"):
        if column_exists("rider_profiles", "payout_provider"):
            op.drop_column("rider_profiles", "payout_provider")
        if column_exists("rider_profiles", "payout_phone"):
            op.drop_column("rider_profiles", "payout_phone")
