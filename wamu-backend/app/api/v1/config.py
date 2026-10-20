"""Public/authenticated config snapshots (feature flags clients need)."""

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user
from app.models.user import User

router = APIRouter()


@router.get("/kyc")
async def get_kyc_config(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """KYC policy for Flutter / admin — merchants off by default until you enable."""
    _ = user
    from app.services import kyc_policy

    return await kyc_policy.get_kyc_policy(db)
