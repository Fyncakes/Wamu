"""0007 — device push tokens for FCM."""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

from migrations.helpers import index_exists, table_exists

revision = "0007_device_push_tokens"
down_revision = "0006_show_read_receipts"
branch_labels = None
depends_on = None


def upgrade() -> None:
    if not table_exists("device_push_tokens"):
        op.create_table(
            "device_push_tokens",
            sa.Column("id", sa.Uuid(), nullable=False),
            sa.Column("user_id", sa.Uuid(), nullable=False),
            sa.Column("token", sa.String(length=512), nullable=False),
            sa.Column("platform", sa.String(length=20), nullable=False),
            sa.Column(
                "updated_at",
                sa.DateTime(timezone=True),
                server_default=sa.text("now()"),
                nullable=False,
            ),
            sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
            sa.PrimaryKeyConstraint("id"),
            sa.UniqueConstraint("token", name="uq_device_push_token"),
        )
    if table_exists("device_push_tokens") and not index_exists(
        "device_push_tokens", "ix_device_push_tokens_user_id"
    ):
        op.create_index("ix_device_push_tokens_user_id", "device_push_tokens", ["user_id"])


def downgrade() -> None:
    if table_exists("device_push_tokens"):
        if index_exists("device_push_tokens", "ix_device_push_tokens_user_id"):
            op.drop_index("ix_device_push_tokens_user_id", table_name="device_push_tokens")
        op.drop_table("device_push_tokens")
