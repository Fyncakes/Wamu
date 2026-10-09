"""0017 — video lifecycle, product link, file size, app settings."""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

from migrations.helpers import column_exists, index_exists, table_exists

revision = "0017_video_lifecycle"
down_revision = "0016_checkout_batch"
branch_labels = None
depends_on = None


def upgrade() -> None:
    if table_exists("business_videos"):
        if not column_exists("business_videos", "status"):
            op.add_column(
                "business_videos",
                sa.Column("status", sa.String(32), nullable=False, server_default="active"),
            )
            if not index_exists("business_videos", "ix_business_videos_status"):
                op.create_index("ix_business_videos_status", "business_videos", ["status"])
        if not column_exists("business_videos", "archived_at"):
            op.add_column(
                "business_videos",
                sa.Column("archived_at", sa.DateTime(timezone=True), nullable=True),
            )
        if not column_exists("business_videos", "permanently_deleted_at"):
            op.add_column(
                "business_videos",
                sa.Column("permanently_deleted_at", sa.DateTime(timezone=True), nullable=True),
            )
        if not column_exists("business_videos", "product_id"):
            op.add_column(
                "business_videos",
                sa.Column("product_id", sa.Uuid(), nullable=True),
            )
            if not index_exists("business_videos", "ix_business_videos_product_id"):
                op.create_index(
                    "ix_business_videos_product_id", "business_videos", ["product_id"]
                )
        if not column_exists("business_videos", "file_size_bytes"):
            op.add_column(
                "business_videos",
                sa.Column("file_size_bytes", sa.Integer(), nullable=True),
            )
        if not column_exists("business_videos", "duration_seconds"):
            op.add_column(
                "business_videos",
                sa.Column("duration_seconds", sa.Integer(), nullable=True),
            )
        if not column_exists("business_videos", "original_video_url"):
            op.add_column(
                "business_videos",
                sa.Column("original_video_url", sa.Text(), nullable=True),
            )

    if not table_exists("app_settings"):
        op.create_table(
            "app_settings",
            sa.Column("key", sa.String(64), primary_key=True),
            sa.Column("value", sa.Text(), nullable=False),
            sa.Column(
                "updated_at",
                sa.DateTime(timezone=True),
                server_default=sa.text("now()"),
                nullable=False,
            ),
        )
        op.execute(
            "INSERT INTO app_settings (key, value) VALUES "
            "('video_archive_after_days', '180'), "
            "('video_purge_after_days', '365')"
        )


def downgrade() -> None:
    if table_exists("app_settings"):
        op.drop_table("app_settings")
    if table_exists("business_videos"):
        for col, idx in (
            ("original_video_url", None),
            ("duration_seconds", None),
            ("file_size_bytes", None),
            ("product_id", "ix_business_videos_product_id"),
            ("permanently_deleted_at", None),
            ("archived_at", None),
            ("status", "ix_business_videos_status"),
        ):
            if idx and index_exists("business_videos", idx):
                op.drop_index(idx, table_name="business_videos")
            if column_exists("business_videos", col):
                op.drop_column("business_videos", col)
