"""0010 — rider rating fields on reviews (Master Plan ratings P0)."""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

from migrations.helpers import column_exists

revision = "0010_rider_ratings"
down_revision = "0009_discover_riders"
branch_labels = None
depends_on = None


def upgrade() -> None:
    if not column_exists("reviews", "rider_id"):
        op.add_column("reviews", sa.Column("rider_id", sa.Uuid(), nullable=True))
        op.create_index("ix_reviews_rider_id", "reviews", ["rider_id"])
    if not column_exists("reviews", "rider_rating"):
        op.add_column("reviews", sa.Column("rider_rating", sa.Integer(), nullable=True))


def downgrade() -> None:
    if column_exists("reviews", "rider_rating"):
        op.drop_column("reviews", "rider_rating")
    if column_exists("reviews", "rider_id"):
        op.drop_index("ix_reviews_rider_id", table_name="reviews")
        op.drop_column("reviews", "rider_id")
