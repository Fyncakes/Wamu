from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.schemas.marketplace import BusinessResponse, ProductResponse
from app.services import product as product_service

router = APIRouter()


@router.get("")
async def search(
    q: str = Query(..., min_length=1, max_length=200),
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
    db: AsyncSession = Depends(get_db),
):
    raw = await product_service.search(db, q=q, page=page, page_size=page_size)
    return {
        "query": raw["query"],
        "businesses": [BusinessResponse.model_validate(b) for b in raw["businesses"]],
        "products": [ProductResponse.model_validate(p) for p in raw["products"]],
    }
