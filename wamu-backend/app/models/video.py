"""Business short videos for Discover feed (Master Plan Phase 3)."""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import Boolean, DateTime, ForeignKey, Integer, String, Text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base
from app.models.mixins import SoftDeleteMixin, TimestampMixin, UUIDMixin

# Lifecycle: Active (in feed) → Archived (hidden, retained) → Permanently deleted.
VIDEO_STATUS_ACTIVE = "active"
VIDEO_STATUS_ARCHIVED = "archived"
VIDEO_STATUS_DELETED = "permanently_deleted"


class BusinessVideo(UUIDMixin, TimestampMixin, SoftDeleteMixin, Base):
    __tablename__ = "business_videos"

    business_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("businesses.id"), nullable=False, index=True
    )
    author_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id"), nullable=False, index=True
    )
    # Optional product/service this clip promotes (survives product soft-delete).
    product_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("products.id", ondelete="SET NULL"), nullable=True, index=True
    )
    caption: Mapped[str | None] = mapped_column(Text)
    video_url: Mapped[str] = mapped_column(Text, nullable=False)
    # Original upload before compression (may be cleared after purge window).
    original_video_url: Mapped[str | None] = mapped_column(Text)
    poster_url: Mapped[str | None] = mapped_column(Text)
    tags: Mapped[str | None] = mapped_column(String(255))  # comma-separated
    like_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    comment_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    view_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    # active | archived | permanently_deleted
    status: Mapped[str] = mapped_column(String(32), nullable=False, default=VIDEO_STATUS_ACTIVE, index=True)
    archived_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    permanently_deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    file_size_bytes: Mapped[int | None] = mapped_column(Integer)
    duration_seconds: Mapped[int | None] = mapped_column(Integer)
    sort_order: Mapped[int] = mapped_column(Integer, nullable=False, default=0)

    business = relationship("Business")
    author = relationship("User")
    product = relationship("Product")


class VideoLike(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "video_likes"

    video_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("business_videos.id", ondelete="CASCADE"), nullable=False, index=True
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )


class BusinessFollow(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "business_followers"

    business_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("businesses.id", ondelete="CASCADE"), nullable=False, index=True
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
