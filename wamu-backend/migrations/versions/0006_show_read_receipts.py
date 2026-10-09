"""0006 — show_read_receipts privacy on user_profiles."""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

from migrations.helpers import column_exists

revision = "0006_show_read_receipts"
down_revision = "0005_platform_fee"
branch_labels = None
depends_on = None


def upgrade() -> None:
    if not column_exists("user_profiles", "show_read_receipts"):
        op.add_column(
            "user_profiles",
            sa.Column(
                "show_read_receipts",
                sa.Boolean(),
                nullable=False,
                server_default=sa.text("true"),
            ),
        )


def downgrade() -> None:
    if column_exists("user_profiles", "show_read_receipts"):
        op.drop_column("user_profiles", "show_read_receipts")
