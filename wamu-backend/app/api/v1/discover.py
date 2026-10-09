"""Discover feed API — vertical business videos."""

from uuid import UUID

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user, get_optional_user
from app.models.user import User
from app.schemas.discover import DiscoverVideoResponse, VideoCreate
from app.services import discover as discover_service

router = APIRouter()


@router.get("/videos", response_model=list[DiscoverVideoResponse])
async def list_discover_videos(
    limit: int = Query(default=30, ge=1, le=50),
    user: User | None = Depends(get_optional_user),
    db: AsyncSession = Depends(get_db),
):
    return await discover_service.list_videos(db, user, limit=limit)


@router.get("/videos/mine", response_model=list[DiscoverVideoResponse])
async def list_my_videos(
    business_id: UUID = Query(...),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await discover_service.list_my_videos(db, user, business_id)


@router.post("/videos", response_model=DiscoverVideoResponse, status_code=201)
async def post_video(
    body: VideoCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await discover_service.create_video(db, user, body)


@router.delete("/videos/{video_id}", status_code=204)
async def delete_video(
    video_id: UUID,
    permanent: bool = Query(default=False),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Archive (default) or permanently delete a merchant's own video."""
    await discover_service.delete_video(db, user, video_id, permanent=permanent)


@router.post("/videos/{video_id}/restore", response_model=DiscoverVideoResponse)
async def restore_video(
    video_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await discover_service.restore_video(db, user, video_id)


@router.post("/videos/{video_id}/like", response_model=DiscoverVideoResponse)
async def like_video(
    video_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await discover_service.like_video(db, user, video_id)


@router.delete("/videos/{video_id}/like", response_model=DiscoverVideoResponse)
async def unlike_video(
    video_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await discover_service.unlike_video(db, user, video_id)


@router.post("/videos/{video_id}/view", status_code=204)
async def view_video(video_id: UUID, db: AsyncSession = Depends(get_db)):
    await discover_service.record_view(db, video_id)


@router.post("/businesses/{business_id}/follow", status_code=201)
async def follow_business(
    business_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await discover_service.follow_business(db, user, business_id)


@router.delete("/businesses/{business_id}/follow", status_code=204)
async def unfollow_business(
    business_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await discover_service.unfollow_business(db, user, business_id)
