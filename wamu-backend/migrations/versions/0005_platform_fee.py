"""0005 — platform fee columns on merchant_payouts (non-custodial)."""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

from migrations.helpers import column_exists, table_exists

revision = "0005_platform_fee"
down_revision = "0004_merchant_payouts"
branch_labels = None
depends_on = None


def upgrade() -> None:
    if not table_exists("merchant_payouts"):
        return
    if not column_exists("merchant_payouts", "platform_fee"):
        op.add_column(
            "merchant_payouts",
            sa.Column(
                "platform_fee",
                sa.Numeric(14, 2),
                nullable=False,
                server_default="0",
            ),
        )
    if not column_exists("merchant_payouts", "fee_bps"):
        op.add_column(
            "merchant_payouts",
            sa.Column("fee_bps", sa.Integer(), nullable=False, server_default="0"),
        )
    # Check may already exist from create_all — ignore duplicate
    try:
        op.create_check_constraint(
            "merchant_payouts_fee_nonneg",
            "merchant_payouts",
            "platform_fee >= 0",
        )
    except Exception:
        pass


def downgrade() -> None:
    if not table_exists("merchant_payouts"):
        return
    try:
        op.drop_constraint("merchant_payouts_fee_nonneg", "merchant_payouts", type_="check")
    except Exception:
        pass
    if column_exists("merchant_payouts", "fee_bps"):
        op.drop_column("merchant_payouts", "fee_bps")
    if column_exists("merchant_payouts", "platform_fee"):
        op.drop_column("merchant_payouts", "platform_fee")
