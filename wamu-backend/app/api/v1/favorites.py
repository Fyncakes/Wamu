from uuid import UUID

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user
from app.models.user import User
from app.schemas.marketplace import BusinessResponse
from app.services import social as social_service

router = APIRouter()


@router.get("", response_model=list[BusinessResponse])
async def list_favorites(
    user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)
):
    return await social_service.list_favorites(db, user)


@router.post("/{business_id}", status_code=201)
async def add_favorite(
    business_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    fav = await social_service.add_favorite(db, user, business_id)
    return {"id": fav.id, "business_id": fav.business_id}


@router.delete("/{business_id}", status_code=204)
async def remove_favorite(
    business_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await social_service.remove_favorite(db, user, business_id)
