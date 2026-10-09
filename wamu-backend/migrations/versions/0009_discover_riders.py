"""0009 — business videos, followers, likes; rider profiles, deliveries, rides; capability flags."""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

from migrations.helpers import column_exists, index_exists, table_exists

revision = "0009_discover_riders"
down_revision = "0008_trust_social"
branch_labels = None
depends_on = None


def upgrade() -> None:
    for col, default in (
        ("wants_to_buy", "true"),
        ("owns_business", "false"),
        ("wants_to_ride", "false"),
    ):
        if not column_exists("user_profiles", col):
            op.add_column(
                "user_profiles",
                sa.Column(col, sa.Boolean(), nullable=False, server_default=default),
            )

    if not table_exists("business_videos"):
        op.create_table(
            "business_videos",
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
            sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("business_id", sa.Uuid(), nullable=False),
            sa.Column("author_id", sa.Uuid(), nullable=False),
            sa.Column("caption", sa.Text(), nullable=True),
            sa.Column("video_url", sa.Text(), nullable=False),
            sa.Column("poster_url", sa.Text(), nullable=True),
            sa.Column("tags", sa.String(length=255), nullable=True),
            sa.Column("like_count", sa.Integer(), nullable=False, server_default="0"),
            sa.Column("comment_count", sa.Integer(), nullable=False, server_default="0"),
            sa.Column("view_count", sa.Integer(), nullable=False, server_default="0"),
            sa.Column("is_active", sa.Boolean(), nullable=False, server_default="true"),
            sa.Column("sort_order", sa.Integer(), nullable=False, server_default="0"),
            sa.ForeignKeyConstraint(["author_id"], ["users.id"]),
            sa.ForeignKeyConstraint(["business_id"], ["businesses.id"]),
            sa.PrimaryKeyConstraint("id"),
        )
    if table_exists("business_videos"):
        if not index_exists("business_videos", "ix_business_videos_business_id"):
            op.create_index("ix_business_videos_business_id", "business_videos", ["business_id"])
        if not index_exists("business_videos", "ix_business_videos_author_id"):
            op.create_index("ix_business_videos_author_id", "business_videos", ["author_id"])

    if not table_exists("video_likes"):
        op.create_table(
            "video_likes",
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
            sa.Column("video_id", sa.Uuid(), nullable=False),
            sa.Column("user_id", sa.Uuid(), nullable=False),
            sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
            sa.ForeignKeyConstraint(["video_id"], ["business_videos.id"], ondelete="CASCADE"),
            sa.PrimaryKeyConstraint("id"),
        )
        op.create_index("ix_video_likes_video_id", "video_likes", ["video_id"])
        op.create_index("ix_video_likes_user_id", "video_likes", ["user_id"])

    if not table_exists("business_followers"):
        op.create_table(
            "business_followers",
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
            sa.Column("business_id", sa.Uuid(), nullable=False),
            sa.Column("user_id", sa.Uuid(), nullable=False),
            sa.ForeignKeyConstraint(["business_id"], ["businesses.id"], ondelete="CASCADE"),
            sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
            sa.PrimaryKeyConstraint("id"),
        )
        op.create_index("ix_business_followers_business_id", "business_followers", ["business_id"])
        op.create_index("ix_business_followers_user_id", "business_followers", ["user_id"])

    if not table_exists("rider_profiles"):
        op.create_table(
            "rider_profiles",
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
            sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("user_id", sa.Uuid(), nullable=False),
            sa.Column("display_name", sa.String(length=120), nullable=False),
            sa.Column("photo_url", sa.Text(), nullable=True),
            sa.Column("wamu_rider_ref", sa.String(length=40), nullable=False),
            sa.Column("vehicle_type", sa.String(length=40), nullable=False, server_default="BODA"),
            sa.Column("plate_number", sa.String(length=40), nullable=True),
            sa.Column("status", sa.String(length=20), nullable=False, server_default="APPROVED"),
            sa.Column("available_delivery", sa.Boolean(), nullable=False, server_default="true"),
            sa.Column("available_rides", sa.Boolean(), nullable=False, server_default="true"),
            sa.Column("rating", sa.Numeric(3, 2), nullable=False, server_default="5.00"),
            sa.Column("delivery_count", sa.Integer(), nullable=False, server_default="0"),
            sa.Column("ride_count", sa.Integer(), nullable=False, server_default="0"),
            sa.Column("lat", sa.Numeric(10, 7), nullable=True),
            sa.Column("lng", sa.Numeric(10, 7), nullable=True),
            sa.ForeignKeyConstraint(["user_id"], ["users.id"]),
            sa.PrimaryKeyConstraint("id"),
            sa.UniqueConstraint("user_id"),
            sa.UniqueConstraint("wamu_rider_ref"),
        )

    if not table_exists("deliveries"):
        op.create_table(
            "deliveries",
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
            sa.Column("order_id", sa.Uuid(), nullable=False),
            sa.Column("rider_id", sa.Uuid(), nullable=True),
            sa.Column("status", sa.String(length=30), nullable=False, server_default="REQUESTED"),
            sa.Column("pickup_address", sa.Text(), nullable=True),
            sa.Column("dropoff_address", sa.Text(), nullable=True),
            sa.Column("pickup_lat", sa.Numeric(10, 7), nullable=True),
            sa.Column("pickup_lng", sa.Numeric(10, 7), nullable=True),
            sa.Column("dropoff_lat", sa.Numeric(10, 7), nullable=True),
            sa.Column("dropoff_lng", sa.Numeric(10, 7), nullable=True),
            sa.Column("rider_lat", sa.Numeric(10, 7), nullable=True),
            sa.Column("rider_lng", sa.Numeric(10, 7), nullable=True),
            sa.Column("fee", sa.Numeric(14, 2), nullable=False, server_default="3000"),
            sa.Column("currency", sa.String(length=3), nullable=False, server_default="UGX"),
            sa.Column("eta_minutes", sa.Integer(), nullable=True),
            sa.ForeignKeyConstraint(["order_id"], ["orders.id"]),
            sa.ForeignKeyConstraint(["rider_id"], ["rider_profiles.id"]),
            sa.PrimaryKeyConstraint("id"),
            sa.UniqueConstraint("order_id"),
        )
        op.create_index("ix_deliveries_order_id", "deliveries", ["order_id"])
        op.create_index("ix_deliveries_rider_id", "deliveries", ["rider_id"])

    if not table_exists("rides"):
        op.create_table(
            "rides",
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
            sa.Column("customer_id", sa.Uuid(), nullable=False),
            sa.Column("rider_id", sa.Uuid(), nullable=True),
            sa.Column("status", sa.String(length=30), nullable=False, server_default="REQUESTED"),
            sa.Column("pickup_address", sa.Text(), nullable=False),
            sa.Column("dropoff_address", sa.Text(), nullable=False),
            sa.Column("pickup_lat", sa.Numeric(10, 7), nullable=True),
            sa.Column("pickup_lng", sa.Numeric(10, 7), nullable=True),
            sa.Column("dropoff_lat", sa.Numeric(10, 7), nullable=True),
            sa.Column("dropoff_lng", sa.Numeric(10, 7), nullable=True),
            sa.Column("rider_lat", sa.Numeric(10, 7), nullable=True),
            sa.Column("rider_lng", sa.Numeric(10, 7), nullable=True),
            sa.Column("fare", sa.Numeric(14, 2), nullable=False, server_default="8000"),
            sa.Column("currency", sa.String(length=3), nullable=False, server_default="UGX"),
            sa.Column("eta_minutes", sa.Integer(), nullable=True),
            sa.ForeignKeyConstraint(["customer_id"], ["users.id"]),
            sa.ForeignKeyConstraint(["rider_id"], ["rider_profiles.id"]),
            sa.PrimaryKeyConstraint("id"),
        )
        op.create_index("ix_rides_customer_id", "rides", ["customer_id"])
        op.create_index("ix_rides_rider_id", "rides", ["rider_id"])


def downgrade() -> None:
    for table in ("rides", "deliveries", "rider_profiles", "business_followers", "video_likes", "business_videos"):
        if table_exists(table):
            op.drop_table(table)
    for col in ("wants_to_ride", "owns_business", "wants_to_buy"):
        if column_exists("user_profiles", col):
            op.drop_column("user_profiles", col)
