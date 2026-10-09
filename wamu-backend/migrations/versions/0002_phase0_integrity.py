"""
0002 — Phase 0 integrity indexes (incremental revision after create_all baseline).

Future schema changes must be explicit ops — never only create_all.
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0002_phase0_integrity"
down_revision = "0001_initial"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # IF NOT EXISTS keeps this safe when models already created indexes via create_all
    statements = [
        "CREATE INDEX IF NOT EXISTS ix_payments_status ON payments (status)",
        "CREATE INDEX IF NOT EXISTS ix_payments_order_id ON payments (order_id)",
        "CREATE INDEX IF NOT EXISTS ix_messages_conversation_created ON messages (conversation_id, created_at)",
        "CREATE INDEX IF NOT EXISTS ix_orders_customer_status ON orders (customer_id, status)",
        "CREATE INDEX IF NOT EXISTS ix_audit_logs_created ON audit_logs (created_at)",
    ]
    for sql in statements:
        try:
            op.execute(sa.text(sql))
        except Exception:
            # Table missing on empty DB before 0001 — ignore; 0001 creates tables first
            pass


def downgrade() -> None:
    for name in (
        "ix_payments_status",
        "ix_payments_order_id",
        "ix_messages_conversation_created",
        "ix_orders_customer_status",
        "ix_audit_logs_created",
    ):
        try:
            op.execute(sa.text(f"DROP INDEX IF EXISTS {name}"))
        except Exception:
            pass
