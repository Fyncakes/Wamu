"""0011 — proof of delivery note on deliveries."""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

from migrations.helpers import column_exists

revision = "0011_proof_of_delivery"
down_revision = "0010_rider_ratings"
branch_labels = None
depends_on = None


def upgrade() -> None:
    if not column_exists("deliveries", "proof_note"):
        op.add_column("deliveries", sa.Column("proof_note", sa.Text(), nullable=True))


def downgrade() -> None:
    if column_exists("deliveries", "proof_note"):
        op.drop_column("deliveries", "proof_note")
