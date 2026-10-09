"""0003 — client_message_id for outbox idempotent sends."""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

from migrations.helpers import column_exists, index_exists, unique_constraint_exists

revision = "0003_client_message_id"
down_revision = "0002_phase0_integrity"
branch_labels = None
depends_on = None


def upgrade() -> None:
    if not column_exists("messages", "client_message_id"):
        op.add_column(
            "messages",
            sa.Column("client_message_id", sa.String(length=80), nullable=True),
        )
    if not index_exists("messages", "ix_messages_client_message_id"):
        op.create_index("ix_messages_client_message_id", "messages", ["client_message_id"])

    dialect = op.get_bind().dialect.name
    if dialect == "sqlite":
        op.execute(
            sa.text(
                "CREATE UNIQUE INDEX IF NOT EXISTS uq_message_client_id "
                "ON messages (conversation_id, sender_id, client_message_id) "
                "WHERE client_message_id IS NOT NULL"
            )
        )
    elif not unique_constraint_exists("messages", "uq_message_client_id"):
        # Partial uniqueness is imperfect on PG without a partial unique index;
        # match historical migration name when missing.
        try:
            op.create_unique_constraint(
                "uq_message_client_id",
                "messages",
                ["conversation_id", "sender_id", "client_message_id"],
            )
        except Exception:
            pass


def downgrade() -> None:
    try:
        op.drop_constraint("uq_message_client_id", "messages", type_="unique")
    except Exception:
        pass
    try:
        op.execute(sa.text("DROP INDEX IF EXISTS uq_message_client_id"))
    except Exception:
        pass
    if index_exists("messages", "ix_messages_client_message_id"):
        op.drop_index("ix_messages_client_message_id", table_name="messages")
    if column_exists("messages", "client_message_id"):
        op.drop_column("messages", "client_message_id")
