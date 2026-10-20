"""0022 — merchant KYC fields + merchant_documents + default policy settings."""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

from migrations.helpers import column_exists, table_exists

revision = "0022_merchant_kyc"
down_revision = "0021_rider_owner_payouts"
branch_labels = None
depends_on = None


def upgrade() -> None:
    if table_exists("businesses"):
        cols = [
            ("kyc_status", sa.Column("kyc_status", sa.String(20), nullable=False, server_default="DRAFT")),
            ("owner_full_name", sa.Column("owner_full_name", sa.String(120), nullable=True)),
            ("owner_nin", sa.Column("owner_nin", sa.String(40), nullable=True)),
            ("owner_date_of_birth", sa.Column("owner_date_of_birth", sa.Date(), nullable=True)),
            ("tin", sa.Column("tin", sa.String(40), nullable=True)),
            ("kyc_ai_result", sa.Column("kyc_ai_result", sa.String(20), nullable=True)),
            ("kyc_ai_checks", sa.Column("kyc_ai_checks", sa.JSON(), nullable=True)),
            ("kyc_ai_ran_at", sa.Column("kyc_ai_ran_at", sa.DateTime(timezone=True), nullable=True)),
            ("kyc_admin_note", sa.Column("kyc_admin_note", sa.Text(), nullable=True)),
            ("kyc_rejection_reason", sa.Column("kyc_rejection_reason", sa.Text(), nullable=True)),
            ("kyc_reupload_fields", sa.Column("kyc_reupload_fields", sa.JSON(), nullable=True)),
            ("kyc_submitted_at", sa.Column("kyc_submitted_at", sa.DateTime(timezone=True), nullable=True)),
            ("kyc_reviewed_at", sa.Column("kyc_reviewed_at", sa.DateTime(timezone=True), nullable=True)),
            (
                "kyc_reviewed_by_id",
                sa.Column(
                    "kyc_reviewed_by_id",
                    UUID(as_uuid=True),
                    sa.ForeignKey("users.id"),
                    nullable=True,
                ),
            ),
        ]
        for name, col in cols:
            if not column_exists("businesses", name):
                op.add_column("businesses", col)

    if not table_exists("merchant_documents"):
        op.create_table(
            "merchant_documents",
            sa.Column("id", UUID(as_uuid=True), primary_key=True),
            sa.Column(
                "business_id",
                UUID(as_uuid=True),
                sa.ForeignKey("businesses.id", ondelete="CASCADE"),
                nullable=False,
                index=True,
            ),
            sa.Column("doc_type", sa.String(40), nullable=False, index=True),
            sa.Column("url", sa.Text(), nullable=False),
            sa.Column("object_key", sa.String(255), nullable=True),
            sa.Column("mime_type", sa.String(80), nullable=True),
            sa.Column("meta", sa.JSON(), nullable=True),
            sa.Column("is_current", sa.Boolean(), nullable=False, server_default=sa.text("true")),
            sa.Column(
                "created_at",
                sa.DateTime(timezone=True),
                server_default=sa.text("CURRENT_TIMESTAMP"),
                nullable=False,
            ),
            sa.Column(
                "updated_at",
                sa.DateTime(timezone=True),
                server_default=sa.text("CURRENT_TIMESTAMP"),
                nullable=False,
            ),
        )

    if table_exists("app_settings"):
        op.execute(
            "INSERT INTO app_settings (key, value) VALUES "
            "('kyc.riders.enforce_online', 'true'), "
            "('kyc.merchants.enabled', 'false'), "
            "('kyc.merchants.require_verified_for_payout', 'false'), "
            "('kyc.merchants.require_verified_for_catalog', 'false'), "
            "('kyc.buyers.enabled', 'false') "
            "ON CONFLICT (key) DO NOTHING"
        )


def downgrade() -> None:
    if table_exists("merchant_documents"):
        op.drop_table("merchant_documents")
    if table_exists("businesses"):
        for name in (
            "kyc_reviewed_by_id",
            "kyc_reviewed_at",
            "kyc_submitted_at",
            "kyc_reupload_fields",
            "kyc_rejection_reason",
            "kyc_admin_note",
            "kyc_ai_ran_at",
            "kyc_ai_checks",
            "kyc_ai_result",
            "tin",
            "owner_date_of_birth",
            "owner_nin",
            "owner_full_name",
            "kyc_status",
        ):
            if column_exists("businesses", name):
                op.drop_column("businesses", name)
