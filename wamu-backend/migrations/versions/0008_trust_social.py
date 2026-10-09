"""0008 — user_blocks, status audience, conversation member role (MVP trust/social)."""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

from migrations.helpers import column_exists, index_exists, table_exists

revision = "0008_trust_social"
down_revision = "0007_device_push_tokens"
branch_labels = None
depends_on = None


def upgrade() -> None:
    if not table_exists("user_blocks"):
        op.create_table(
            "user_blocks",
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
            sa.Column("blocker_id", sa.Uuid(), nullable=False),
            sa.Column("blocked_id", sa.Uuid(), nullable=False),
            sa.ForeignKeyConstraint(["blocked_id"], ["users.id"], ondelete="CASCADE"),
            sa.ForeignKeyConstraint(["blocker_id"], ["users.id"], ondelete="CASCADE"),
            sa.PrimaryKeyConstraint("id"),
            sa.UniqueConstraint("blocker_id", "blocked_id", name="uq_user_block_pair"),
        )
    if table_exists("user_blocks") and not index_exists("user_blocks", "ix_user_blocks_blocker_id"):
        op.create_index("ix_user_blocks_blocker_id", "user_blocks", ["blocker_id"])
    if table_exists("user_blocks") and not index_exists("user_blocks", "ix_user_blocks_blocked_id"):
        op.create_index("ix_user_blocks_blocked_id", "user_blocks", ["blocked_id"])

    if not column_exists("status_updates", "audience"):
        op.add_column(
            "status_updates",
            sa.Column(
                "audience",
                sa.String(length=20),
                nullable=False,
                server_default="CONTACTS",
            ),
        )

    if not column_exists("conversation_members", "member_role"):
        op.add_column(
            "conversation_members",
            sa.Column(
                "member_role",
                sa.String(length=20),
                nullable=False,
                server_default="MEMBER",
            ),
        )


def downgrade() -> None:
    if column_exists("conversation_members", "member_role"):
        op.drop_column("conversation_members", "member_role")
    if column_exists("status_updates", "audience"):
        op.drop_column("status_updates", "audience")
    if table_exists("user_blocks"):
        if index_exists("user_blocks", "ix_user_blocks_blocked_id"):
            op.drop_index("ix_user_blocks_blocked_id", table_name="user_blocks")
        if index_exists("user_blocks", "ix_user_blocks_blocker_id"):
            op.drop_index("ix_user_blocks_blocker_id", table_name="user_blocks")
        op.drop_table("user_blocks")
