"""0014 — conversation hide-for-me + per-user message hides."""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

from migrations.helpers import column_exists, table_exists

revision = "0014_chat_silent_delete"
down_revision = "0013_rider_verification"
branch_labels = None
depends_on = None


def upgrade() -> None:
    if table_exists("conversation_members") and not column_exists("conversation_members", "hidden_at"):
        op.add_column(
            "conversation_members",
            sa.Column("hidden_at", sa.DateTime(timezone=True), nullable=True),
        )
    if not table_exists("message_hides"):
        op.create_table(
            "message_hides",
            sa.Column("id", sa.Uuid(), nullable=False),
            sa.Column("message_id", sa.Uuid(), nullable=False),
            sa.Column("user_id", sa.Uuid(), nullable=False),
            sa.Column(
                "created_at",
                sa.DateTime(timezone=True),
                server_default=sa.text("now()"),
                nullable=False,
            ),
            sa.ForeignKeyConstraint(["message_id"], ["messages.id"], ondelete="CASCADE"),
            sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
            sa.PrimaryKeyConstraint("id"),
            sa.UniqueConstraint("message_id", "user_id", name="uq_message_hide_user"),
        )
        op.create_index("ix_message_hides_message_id", "message_hides", ["message_id"])
        op.create_index("ix_message_hides_user_id", "message_hides", ["user_id"])


def downgrade() -> None:
    if table_exists("message_hides"):
        op.drop_table("message_hides")
    if table_exists("conversation_members") and column_exists("conversation_members", "hidden_at"):
        op.drop_column("conversation_members", "hidden_at")
