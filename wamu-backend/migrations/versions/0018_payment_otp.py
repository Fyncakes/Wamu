"""0018 — Wamu MoMo OTP challenges for MTN / Airtel payments."""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

from migrations.helpers import table_exists

revision = "0018_payment_otp"
down_revision = "0017_video_lifecycle"
branch_labels = None
depends_on = None


def upgrade() -> None:
    if table_exists("payment_otp_challenges"):
        return
    op.create_table(
        "payment_otp_challenges",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "payment_id",
            UUID(as_uuid=True),
            sa.ForeignKey("payments.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("phone", sa.String(20), nullable=False),
        sa.Column("provider", sa.String(20), nullable=False),
        sa.Column("code_hash", sa.Text(), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("attempts", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("consumed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("CURRENT_TIMESTAMP"),
            nullable=False,
        ),
    )
    op.create_index(
        "ix_payment_otp_challenges_payment_id",
        "payment_otp_challenges",
        ["payment_id"],
    )
    op.create_index(
        "ix_payment_otp_challenges_phone",
        "payment_otp_challenges",
        ["phone"],
    )


def downgrade() -> None:
    if table_exists("payment_otp_challenges"):
        op.drop_table("payment_otp_challenges")
