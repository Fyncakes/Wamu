from uuid import UUID

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user
from app.models.user import User
from app.schemas.commerce import ReviewCreate, ReviewReply, ReviewResponse
from app.services import social as social_service

router = APIRouter()


@router.post("", response_model=ReviewResponse, status_code=201)
async def create_review(
    body: ReviewCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await social_service.create_review(db, user, body)


@router.get("/business/{business_id}", response_model=list[ReviewResponse])
async def list_reviews(business_id: UUID, db: AsyncSession = Depends(get_db)):
    return await social_service.list_reviews(db, business_id)


@router.post("/{review_id}/reply", response_model=ReviewResponse)
async def reply(
    review_id: UUID,
    body: ReviewReply,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await social_service.reply_review(db, user, review_id, body)
