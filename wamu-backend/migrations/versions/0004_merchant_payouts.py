"""0004 — merchant payouts + business payout destination."""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

from migrations.helpers import column_exists, index_exists, table_exists

revision = "0004_merchant_payouts"
down_revision = "0003_client_message_id"
branch_labels = None
depends_on = None


def upgrade() -> None:
    if not column_exists("businesses", "payout_phone"):
        op.add_column("businesses", sa.Column("payout_phone", sa.String(length=20), nullable=True))
    if not column_exists("businesses", "payout_provider"):
        op.add_column(
            "businesses", sa.Column("payout_provider", sa.String(length=20), nullable=True)
        )

    if not table_exists("merchant_payouts"):
        op.create_table(
            "merchant_payouts",
            sa.Column("id", sa.Uuid(), nullable=False),
            sa.Column(
                "created_at",
                sa.DateTime(timezone=True),
                server_default=sa.text("now()"),
                nullable=False,
            ),
            sa.Column(
                "updated_at",
                sa.DateTime(timezone=True),
                server_default=sa.text("now()"),
                nullable=False,
            ),
            sa.Column("payment_id", sa.Uuid(), nullable=False),
            sa.Column("order_id", sa.Uuid(), nullable=False),
            sa.Column("business_id", sa.Uuid(), nullable=False),
            sa.Column("amount", sa.Numeric(14, 2), nullable=False),
            sa.Column("currency", sa.String(length=3), nullable=False),
            sa.Column("provider", sa.String(length=20), nullable=False),
            sa.Column("provider_reference", sa.String(length=100), nullable=True),
            sa.Column("idempotency_key", sa.String(length=100), nullable=False),
            sa.Column("payee_phone", sa.String(length=20), nullable=False),
            sa.Column("status", sa.String(length=20), nullable=False),
            sa.Column("raw_response", sa.JSON(), nullable=True),
            sa.CheckConstraint("amount > 0", name="merchant_payouts_amount_positive"),
            sa.CheckConstraint("currency = 'UGX'", name="merchant_payouts_currency_ugx"),
            sa.ForeignKeyConstraint(["business_id"], ["businesses.id"]),
            sa.ForeignKeyConstraint(["order_id"], ["orders.id"]),
            sa.ForeignKeyConstraint(["payment_id"], ["payments.id"]),
            sa.PrimaryKeyConstraint("id"),
            sa.UniqueConstraint("business_id", "idempotency_key", name="uq_merchant_payout_idempotency"),
            sa.UniqueConstraint("payment_id", name="uq_merchant_payout_payment"),
            sa.UniqueConstraint(
                "provider", "provider_reference", name="uq_merchant_payout_provider_ref"
            ),
        )

    for name, cols in (
        ("ix_merchant_payouts_business_id", ["business_id"]),
        ("ix_merchant_payouts_order_id", ["order_id"]),
        ("ix_merchant_payouts_payment_id", ["payment_id"]),
        ("ix_merchant_payouts_status", ["status"]),
    ):
        if table_exists("merchant_payouts") and not index_exists("merchant_payouts", name):
            op.create_index(name, "merchant_payouts", cols)


def downgrade() -> None:
    if table_exists("merchant_payouts"):
        for name in (
            "ix_merchant_payouts_status",
            "ix_merchant_payouts_payment_id",
            "ix_merchant_payouts_order_id",
            "ix_merchant_payouts_business_id",
        ):
            if index_exists("merchant_payouts", name):
                op.drop_index(name, table_name="merchant_payouts")
        op.drop_table("merchant_payouts")
    if column_exists("businesses", "payout_provider"):
        op.drop_column("businesses", "payout_provider")
    if column_exists("businesses", "payout_phone"):
        op.drop_column("businesses", "payout_phone")
