"""0015 — one-time QR device-link challenges."""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

from migrations.helpers import table_exists

revision = "0015_device_link"
down_revision = "0014_chat_silent_delete"
branch_labels = None
depends_on = None


def upgrade() -> None:
    if table_exists("device_link_challenges"):
        return
    op.create_table(
        "device_link_challenges",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("token_hash", sa.Text(), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("consumed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("claimed_device_name", sa.String(length=255), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("token_hash"),
    )
    op.create_index("ix_device_link_challenges_user_id", "device_link_challenges", ["user_id"])
    op.create_index("ix_device_link_challenges_expires_at", "device_link_challenges", ["expires_at"])


def downgrade() -> None:
    if table_exists("device_link_challenges"):
        op.drop_table("device_link_challenges")
