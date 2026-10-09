from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.database import get_db
from app.core.deps import get_current_user
from app.models.user import User
from app.schemas.auth import PrivacyUpdate, UserProfileUpdate, UserResponse
from app.services import trust as trust_service

router = APIRouter()


@router.get("/me", response_model=UserResponse)
async def me(user: User = Depends(get_current_user)):
    return user


@router.patch("/me/profile", response_model=UserResponse)
async def update_profile(
    body: UserProfileUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    if user.profile is None:
        from app.models.user import UserProfile

        user.profile = UserProfile(user_id=user.id)
        db.add(user.profile)
        await db.flush()
    for field, value in body.model_dump(exclude_unset=True).items():
        setattr(user.profile, field, value)
    await db.flush()
    await db.refresh(user)
    return user


@router.patch("/me/privacy", response_model=UserResponse)
async def update_privacy(
    body: PrivacyUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    if user.profile is None:
        from app.models.user import UserProfile

        user.profile = UserProfile(user_id=user.id)
        db.add(user.profile)
        await db.flush()
    data = body.model_dump(exclude_unset=True)
    if "show_last_seen" in data:
        user.profile.show_last_seen = bool(data["show_last_seen"])
    if "show_online" in data:
        user.profile.show_online = bool(data["show_online"])
    if "show_read_receipts" in data:
        user.profile.show_read_receipts = bool(data["show_read_receipts"])
    await db.flush()
    await db.refresh(user)
    return user


@router.get("/me/blocks", response_model=list[UserResponse])
async def list_blocks(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await trust_service.list_blocked(db, user)


@router.post("/me/blocks/{blocked_id}", response_model=dict, status_code=201)
async def block_user(
    blocked_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await trust_service.block_user(db, user, blocked_id)
    return {"status": "blocked", "user_id": str(blocked_id)}


@router.delete("/me/blocks/{blocked_id}", response_model=dict)
async def unblock_user(
    blocked_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await trust_service.unblock_user(db, user, blocked_id)


@router.get("/{user_id}", response_model=UserResponse)
async def get_user(
    user_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    if await trust_service.is_blocked_either_way(db, user.id, user_id):
        raise HTTPException(status_code=404, detail="User not found")
    peer = await db.scalar(
        select(User).options(selectinload(User.profile)).where(User.id == user_id)
    )
    if peer is None or peer.status != "ACTIVE":
        raise HTTPException(status_code=404, detail="User not found")
    return peer
