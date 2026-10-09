"""0013 — rider KYC verification fields + rider_documents."""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

from migrations.helpers import column_exists, table_exists

revision = "0013_rider_verification"
down_revision = "0012_order_disputes"
branch_labels = None
depends_on = None

_RIDER_COLS = [
    ("date_of_birth", sa.Column("date_of_birth", sa.Date(), nullable=True)),
    ("nin", sa.Column("nin", sa.String(40), nullable=True)),
    ("emergency_contact_name", sa.Column("emergency_contact_name", sa.String(120), nullable=True)),
    ("emergency_contact_phone", sa.Column("emergency_contact_phone", sa.String(20), nullable=True)),
    ("location_text", sa.Column("location_text", sa.String(255), nullable=True)),
    ("licence_number", sa.Column("licence_number", sa.String(60), nullable=True)),
    ("licence_expiry", sa.Column("licence_expiry", sa.Date(), nullable=True)),
    ("licence_class", sa.Column("licence_class", sa.String(40), nullable=True)),
    ("motorcycle_reg", sa.Column("motorcycle_reg", sa.String(40), nullable=True)),
    ("motorcycle_ownership", sa.Column("motorcycle_ownership", sa.String(255), nullable=True)),
    ("insurance_policy", sa.Column("insurance_policy", sa.String(80), nullable=True)),
    ("insurance_reg", sa.Column("insurance_reg", sa.String(40), nullable=True)),
    ("insurance_valid_from", sa.Column("insurance_valid_from", sa.Date(), nullable=True)),
    ("insurance_valid_to", sa.Column("insurance_valid_to", sa.Date(), nullable=True)),
    ("ai_result", sa.Column("ai_result", sa.String(20), nullable=True)),
    ("ai_checks", sa.Column("ai_checks", sa.JSON(), nullable=True)),
    ("ai_ran_at", sa.Column("ai_ran_at", sa.DateTime(timezone=True), nullable=True)),
    ("admin_note", sa.Column("admin_note", sa.Text(), nullable=True)),
    ("rejection_reason", sa.Column("rejection_reason", sa.Text(), nullable=True)),
    ("reupload_fields", sa.Column("reupload_fields", sa.JSON(), nullable=True)),
    ("submitted_at", sa.Column("submitted_at", sa.DateTime(timezone=True), nullable=True)),
    ("reviewed_at", sa.Column("reviewed_at", sa.DateTime(timezone=True), nullable=True)),
    ("reviewed_by_id", sa.Column("reviewed_by_id", sa.Uuid(), nullable=True)),
]


def upgrade() -> None:
    if table_exists("rider_profiles"):
        for name, col in _RIDER_COLS:
            if not column_exists("rider_profiles", name):
                op.add_column("rider_profiles", col)

    if not table_exists("rider_documents"):
        op.create_table(
            "rider_documents",
            sa.Column("id", sa.Uuid(), primary_key=True, nullable=False),
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
            sa.Column("rider_id", sa.Uuid(), sa.ForeignKey("rider_profiles.id"), nullable=False),
            sa.Column("doc_type", sa.String(40), nullable=False),
            sa.Column("url", sa.Text(), nullable=False),
            sa.Column("object_key", sa.String(255), nullable=True),
            sa.Column("mime_type", sa.String(80), nullable=True),
            sa.Column("meta", sa.JSON(), nullable=True),
            sa.Column("is_current", sa.Boolean(), nullable=False, server_default=sa.text("1")),
        )
        op.create_index("ix_rider_documents_rider_id", "rider_documents", ["rider_id"])
        op.create_index("ix_rider_documents_doc_type", "rider_documents", ["doc_type"])


def downgrade() -> None:
    if table_exists("rider_documents"):
        op.drop_table("rider_documents")
    if table_exists("rider_profiles"):
        for name, _ in reversed(_RIDER_COLS):
            if column_exists("rider_profiles", name):
                op.drop_column("rider_profiles", name)
