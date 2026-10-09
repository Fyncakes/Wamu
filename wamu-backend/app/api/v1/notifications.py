from uuid import UUID

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user
from app.models.user import User
from app.schemas.commerce import NotificationResponse
from app.services import social as social_service

router = APIRouter()


@router.get("", response_model=list[NotificationResponse])
async def list_notifications(
    user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)
):
    return await social_service.list_notifications(db, user)


@router.post("/{notification_id}/read", response_model=NotificationResponse)
async def mark_read(
    notification_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await social_service.mark_notification_read(db, user, notification_id)
