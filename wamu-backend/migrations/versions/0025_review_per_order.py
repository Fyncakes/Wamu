"""0025 — one review per order (drop business+user unique)."""

from __future__ import annotations

from alembic import op

from migrations.helpers import table_exists, unique_constraint_exists

revision = "0025_review_per_order"
down_revision = "0024_message_receipts"
branch_labels = None
depends_on = None


def upgrade() -> None:
    if not table_exists("reviews"):
        return
    if unique_constraint_exists("reviews", "uq_review_business_user"):
        op.drop_constraint("uq_review_business_user", "reviews", type_="unique")
    if not unique_constraint_exists("reviews", "uq_review_order"):
        # Nullable legacy rows: unique still allows multiple NULLs in Postgres.
        op.create_unique_constraint("uq_review_order", "reviews", ["order_id"])


def downgrade() -> None:
    if not table_exists("reviews"):
        return
    if unique_constraint_exists("reviews", "uq_review_order"):
        op.drop_constraint("uq_review_order", "reviews", type_="unique")
    if not unique_constraint_exists("reviews", "uq_review_business_user"):
        op.create_unique_constraint(
            "uq_review_business_user", "reviews", ["business_id", "user_id"]
        )
