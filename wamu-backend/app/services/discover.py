"""Discover video feed — commerce-linked short video + lifecycle."""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.business import Business
from app.models.product import Product
from app.models.user import User
from app.models.video import (
    VIDEO_STATUS_ACTIVE,
    VIDEO_STATUS_ARCHIVED,
    VIDEO_STATUS_DELETED,
    BusinessFollow,
    BusinessVideo,
    VideoLike,
)
from app.schemas.discover import DiscoverVideoResponse, VideoCreate
from app.services import app_settings as settings_service
from app.services.business import assert_business_member
from app.services.video_processing import media_path_from_url


def _disk_size(video_url: str | None) -> int:
    from app.core.media_root import media_file_from_url

    if not video_url:
        return 10**12
    f = media_file_from_url(video_url)
    if f is None:
        return 10**12
    try:
        return f.stat().st_size
    except OSError:
        return 10**12


async def _products_by_business(
    db: AsyncSession, business_ids: set[uuid.UUID]
) -> dict[uuid.UUID, Product]:
    """Newest active product per business (fallback when video has no product_id)."""
    if not business_ids:
        return {}
    result = await db.execute(
        select(Product)
        .where(
            Product.business_id.in_(business_ids),
            Product.deleted_at.is_(None),
            Product.is_active.is_(True),
        )
        .order_by(Product.created_at.desc())
    )
    out: dict[uuid.UUID, Product] = {}
    for p in result.scalars().all():
        if p.business_id not in out:
            out[p.business_id] = p
    return out


def _to_response(
    video: BusinessVideo,
    *,
    liked: bool,
    following: bool,
    product: Product | None,
) -> DiscoverVideoResponse:
    biz = video.business
    return DiscoverVideoResponse(
        id=video.id,
        business_id=video.business_id,
        business_name=biz.name if biz else "Business",
        business_logo_url=biz.logo_url if biz else None,
        author_id=video.author_id,
        caption=video.caption,
        video_url=video.video_url,
        poster_url=video.poster_url,
        tags=video.tags,
        like_count=video.like_count,
        comment_count=video.comment_count,
        view_count=video.view_count,
        liked_by_me=liked,
        following=following,
        product_id=product.id if product else None,
        product_name=product.name if product else None,
        product_price=product.price if product else None,
        currency=product.currency if product else "UGX",
        status=video.status or VIDEO_STATUS_ACTIVE,
        file_size_bytes=video.file_size_bytes,
        created_at=video.created_at,
    )


async def _enrich(
    db: AsyncSession, videos: list[BusinessVideo], user: User | None
) -> list[DiscoverVideoResponse]:
    if not videos:
        return []

    video_ids = [v.id for v in videos]
    business_ids = {v.business_id for v in videos}
    product_ids = {v.product_id for v in videos if v.product_id}

    liked_ids: set[uuid.UUID] = set()
    following_ids: set[uuid.UUID] = set()
    if user:
        liked_rows = await db.execute(
            select(VideoLike.video_id).where(
                VideoLike.user_id == user.id, VideoLike.video_id.in_(video_ids)
            )
        )
        liked_ids = set(liked_rows.scalars().all())
        follow_rows = await db.execute(
            select(BusinessFollow.business_id).where(
                BusinessFollow.user_id == user.id,
                BusinessFollow.business_id.in_(business_ids),
            )
        )
        following_ids = set(follow_rows.scalars().all())

    linked_products: dict[uuid.UUID, Product] = {}
    if product_ids:
        prod_rows = await db.execute(
            select(Product).where(Product.id.in_(product_ids), Product.deleted_at.is_(None))
        )
        linked_products = {p.id: p for p in prod_rows.scalars().all()}

    featured = await _products_by_business(db, business_ids)

    out: list[DiscoverVideoResponse] = []
    for v in videos:
        product = None
        if v.product_id and v.product_id in linked_products:
            product = linked_products[v.product_id]
        else:
            product = featured.get(v.business_id)
        out.append(
            _to_response(
                v,
                liked=v.id in liked_ids,
                following=v.business_id in following_ids,
                product=product,
            )
        )
    return out


def _backfill_sizes(videos: list[BusinessVideo]) -> None:
    for v in videos:
        if not v.file_size_bytes:
            sz = _disk_size(v.video_url)
            if sz < 10**12:
                v.file_size_bytes = sz


def _diversify_newest(videos: list[BusinessVideo], *, max_streak: int = 2) -> list[BusinessVideo]:
    """Keep newest-first order but avoid one merchant owning a long streak.

    When many shops upload at once, limited consecutive clips from the same
    business keeps the feed fair without burying brand-new posts.
    """
    remaining = list(videos)
    out: list[BusinessVideo] = []
    streak_biz: str | None = None
    streak = 0
    while remaining:
        picked_i = None
        for i, v in enumerate(remaining):
            bid = str(v.business_id)
            if streak_biz == bid and streak >= max_streak:
                continue
            picked_i = i
            break
        if picked_i is None:
            picked_i = 0
        picked = remaining.pop(picked_i)
        bid = str(picked.business_id)
        if streak_biz == bid:
            streak += 1
        else:
            streak_biz = bid
            streak = 1
        out.append(picked)
    return out


async def list_videos(
    db: AsyncSession,
    user: User | None,
    *,
    limit: int = 30,
    offset: int = 0,
) -> list[DiscoverVideoResponse]:
    # Over-fetch a bit so URL dedupe + merchant diversity still fill `limit`.
    fetch_n = min(max(limit * 3, limit + 20), 150)
    result = await db.execute(
        select(BusinessVideo)
        .options(selectinload(BusinessVideo.business))
        .where(
            BusinessVideo.deleted_at.is_(None),
            BusinessVideo.is_active.is_(True),
            BusinessVideo.status == VIDEO_STATUS_ACTIVE,
        )
        # New merchant uploads surface at the top.
        .order_by(BusinessVideo.created_at.desc(), BusinessVideo.sort_order.asc())
        .offset(max(offset, 0))
        .limit(fetch_n)
    )
    videos = list(result.scalars().all())
    from app.core.media_root import local_media_missing
    from app.services.business import _repair_shop_logos

    await _repair_shop_logos(db, [v.business for v in videos if v.business is not None])
    # A redeploy used to delete the file while the row stayed. Skip those clips
    # so the phone does not sit on "tap to retry" for a video that is gone.
    videos = [v for v in videos if not local_media_missing(v.video_url)]
    # Drop duplicate encodings of the same clip (seed/manifest duplicates).
    seen_urls: set[str] = set()
    unique: list[BusinessVideo] = []
    for v in videos:
        key = (v.video_url or "").split("?")[0].rstrip("/")
        if key and key in seen_urls:
            continue
        if key:
            seen_urls.add(key)
        unique.append(v)
    videos = _diversify_newest(unique)[: min(limit, 50)]
    _backfill_sizes(videos)
    return await _enrich(db, videos, user)


async def list_my_videos(
    db: AsyncSession, user: User, business_id: uuid.UUID
) -> list[DiscoverVideoResponse]:
    await assert_business_member(db, user, business_id)
    result = await db.execute(
        select(BusinessVideo)
        .options(selectinload(BusinessVideo.business))
        .where(
            BusinessVideo.business_id == business_id,
            BusinessVideo.deleted_at.is_(None),
            BusinessVideo.status != VIDEO_STATUS_DELETED,
        )
        .order_by(BusinessVideo.created_at.desc())
        .limit(100)
    )
    videos = list(result.scalars().all())
    return await _enrich(db, videos, user)


async def create_video(db: AsyncSession, user: User, data: VideoCreate) -> DiscoverVideoResponse:
    await assert_business_member(db, user, data.business_id)
    product_id = data.product_id
    if product_id:
        product = await db.get(Product, product_id)
        if (
            not product
            or product.deleted_at
            or product.business_id != data.business_id
        ):
            raise HTTPException(status_code=400, detail="Product not found for this shop")
    size = data.file_size_bytes if data.file_size_bytes else _disk_size(data.video_url)
    from app.services.video_processing import (
        VideoDurationError,
        assert_short_duration,
        media_path_from_url,
        probe_duration_seconds,
    )

    try:
        if data.duration_seconds is not None:
            duration_s = assert_short_duration(float(data.duration_seconds))
        else:
            local = media_path_from_url(data.video_url)
            if local is None:
                raise HTTPException(
                    status_code=400,
                    detail=(
                        "Shorts must be at most 1.5 minutes (90 seconds). "
                        "Upload from gallery so length can be checked."
                    ),
                )
            duration_s = assert_short_duration(probe_duration_seconds(local))
    except VideoDurationError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    video = BusinessVideo(
        business_id=data.business_id,
        author_id=user.id,
        product_id=product_id,
        caption=data.caption,
        video_url=data.video_url,
        original_video_url=data.original_video_url,
        poster_url=data.poster_url,
        tags=data.tags,
        status=VIDEO_STATUS_ACTIVE,
        is_active=True,
        file_size_bytes=size if size and size < 10**12 else None,
        duration_seconds=duration_s,
    )
    db.add(video)
    await db.flush()
    await db.refresh(video, attribute_names=["business"])
    if video.business is None:
        video.business = await db.get(Business, data.business_id)
    rows = await _enrich(db, [video], user)
    return rows[0]


async def delete_video(
    db: AsyncSession, user: User, video_id: uuid.UUID, *, permanent: bool = False
) -> None:
    """
    Merchant remove from feed:
    - default → Archived (restorable)
    - permanent=True → Permanently deleted + drop local files
    """
    video = await db.scalar(
        select(BusinessVideo).where(
            BusinessVideo.id == video_id,
            BusinessVideo.status != VIDEO_STATUS_DELETED,
        )
    )
    if not video:
        raise HTTPException(status_code=404, detail="Video not found")
    await assert_business_member(db, user, video.business_id)
    now = datetime.now(timezone.utc)
    if permanent:
        await purge_video_files(video)
        video.status = VIDEO_STATUS_DELETED
        video.is_active = False
        video.deleted_at = now
        video.permanently_deleted_at = now
    else:
        video.status = VIDEO_STATUS_ARCHIVED
        video.is_active = False
        video.archived_at = now
        video.deleted_at = None
    await db.flush()


async def restore_video(db: AsyncSession, user: User, video_id: uuid.UUID) -> DiscoverVideoResponse:
    """Bring an archived clip back to Active (merchant only)."""
    video = await db.scalar(
        select(BusinessVideo)
        .options(selectinload(BusinessVideo.business))
        .where(BusinessVideo.id == video_id, BusinessVideo.status == VIDEO_STATUS_ARCHIVED)
    )
    if not video:
        raise HTTPException(status_code=404, detail="Archived video not found")
    await assert_business_member(db, user, video.business_id)
    video.status = VIDEO_STATUS_ACTIVE
    video.is_active = True
    video.archived_at = None
    video.deleted_at = None
    await db.flush()
    rows = await _enrich(db, [video], user)
    return rows[0]


async def archive_video(db: AsyncSession, video: BusinessVideo, *, now: datetime | None = None) -> None:
    now = now or datetime.now(timezone.utc)
    if video.status != VIDEO_STATUS_ACTIVE:
        return
    video.status = VIDEO_STATUS_ARCHIVED
    video.is_active = False
    video.archived_at = now
    await db.flush()


async def purge_video_files(video: BusinessVideo) -> None:
    """Remove encoded + original bytes from local disk (S3 keys left for later)."""
    for url in (video.video_url, video.original_video_url, video.poster_url):
        path = media_path_from_url(url or "")
        if path and path.is_file():
            try:
                path.unlink()
            except OSError:
                pass
            # Compression backups written as path.mp4.orig
            sibling = Path(str(path) + ".orig")
            if sibling.is_file():
                try:
                    sibling.unlink()
                except OSError:
                    pass


async def run_video_lifecycle(db: AsyncSession) -> dict:
    """
    Active → Archived after archive_after_days (age from created_at).
    Archived → Permanently deleted after purge_after_days; then drop local files.
    Never archives based on low views/likes.
    """
    retention = await settings_service.get_video_retention(db)
    now = datetime.now(timezone.utc)
    archive_before = now - timedelta(days=retention["archive_after_days"])
    purge_before = now - timedelta(days=retention["purge_after_days"])

    archived = 0
    purged = 0

    to_archive = (
        await db.execute(
            select(BusinessVideo).where(
                BusinessVideo.deleted_at.is_(None),
                BusinessVideo.status == VIDEO_STATUS_ACTIVE,
                BusinessVideo.created_at < archive_before,
            )
        )
    ).scalars().all()
    for v in to_archive:
        await archive_video(db, v, now=now)
        archived += 1

    to_purge = (
        await db.execute(
            select(BusinessVideo).where(
                BusinessVideo.status == VIDEO_STATUS_ARCHIVED,
                BusinessVideo.archived_at.is_not(None),
                BusinessVideo.archived_at < purge_before,
            )
        )
    ).scalars().all()
    for v in to_purge:
        await purge_video_files(v)
        v.status = VIDEO_STATUS_DELETED
        v.is_active = False
        v.deleted_at = now
        v.permanently_deleted_at = now
        purged += 1

    await db.flush()
    return {
        "archived": archived,
        "purged": purged,
        "archive_after_days": retention["archive_after_days"],
        "purge_after_days": retention["purge_after_days"],
    }


async def like_video(db: AsyncSession, user: User, video_id: uuid.UUID) -> DiscoverVideoResponse:
    video = await db.scalar(
        select(BusinessVideo)
        .options(selectinload(BusinessVideo.business))
        .where(
            BusinessVideo.id == video_id,
            BusinessVideo.deleted_at.is_(None),
            BusinessVideo.status == VIDEO_STATUS_ACTIVE,
        )
    )
    if not video:
        raise HTTPException(status_code=404, detail="Video not found")
    existing = await db.scalar(
        select(VideoLike).where(VideoLike.video_id == video.id, VideoLike.user_id == user.id)
    )
    if not existing:
        db.add(VideoLike(video_id=video.id, user_id=user.id))
        video.like_count = (video.like_count or 0) + 1
        await db.flush()
    rows = await _enrich(db, [video], user)
    return rows[0]


async def unlike_video(db: AsyncSession, user: User, video_id: uuid.UUID) -> DiscoverVideoResponse:
    video = await db.scalar(
        select(BusinessVideo)
        .options(selectinload(BusinessVideo.business))
        .where(
            BusinessVideo.id == video_id,
            BusinessVideo.deleted_at.is_(None),
            BusinessVideo.status == VIDEO_STATUS_ACTIVE,
        )
    )
    if not video:
        raise HTTPException(status_code=404, detail="Video not found")
    existing = await db.scalar(
        select(VideoLike).where(VideoLike.video_id == video.id, VideoLike.user_id == user.id)
    )
    if existing:
        await db.delete(existing)
        video.like_count = max(0, (video.like_count or 0) - 1)
        await db.flush()
    rows = await _enrich(db, [video], user)
    return rows[0]


async def follow_business(db: AsyncSession, user: User, business_id: uuid.UUID) -> dict:
    biz = await db.get(Business, business_id)
    if not biz or biz.deleted_at:
        raise HTTPException(status_code=404, detail="Business not found")
    existing = await db.scalar(
        select(BusinessFollow).where(
            BusinessFollow.business_id == business_id, BusinessFollow.user_id == user.id
        )
    )
    if not existing:
        db.add(BusinessFollow(business_id=business_id, user_id=user.id))
        await db.flush()
    return {"following": True, "business_id": str(business_id)}


async def unfollow_business(db: AsyncSession, user: User, business_id: uuid.UUID) -> None:
    existing = await db.scalar(
        select(BusinessFollow).where(
            BusinessFollow.business_id == business_id, BusinessFollow.user_id == user.id
        )
    )
    if existing:
        await db.delete(existing)
        await db.flush()


async def record_view(db: AsyncSession, video_id: uuid.UUID) -> None:
    video = await db.get(BusinessVideo, video_id)
    if video and not video.deleted_at and video.status == VIDEO_STATUS_ACTIVE:
        video.view_count = (video.view_count or 0) + 1
        await db.flush()


async def on_product_unavailable(db: AsyncSession, product_id: uuid.UUID) -> int:
    """
    Product soft-deleted / deactivated: keep promotional videos, clear commerce link.
    Videos stay Active and go through normal age-based lifecycle — never auto-deleted for engagement.
    """
    result = await db.execute(
        select(BusinessVideo).where(
            BusinessVideo.product_id == product_id,
            BusinessVideo.deleted_at.is_(None),
            BusinessVideo.status != VIDEO_STATUS_DELETED,
        )
    )
    videos = list(result.scalars().all())
    for v in videos:
        v.product_id = None
    await db.flush()
    return len(videos)
