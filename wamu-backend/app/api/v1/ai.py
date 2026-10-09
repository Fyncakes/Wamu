from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user
from app.models.user import User
from app.schemas.commerce import AISearchRequest, AISearchResponse
from app.services import social as social_service

router = APIRouter()


@router.post("/search", response_model=AISearchResponse)
async def ai_search(
    body: AISearchRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    # Auth required so we can personalize later; Level-1 uses catalog only.
    _ = user
    return await social_service.ai_search(db, body)
