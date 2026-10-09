from uuid import UUID

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_admin, get_current_user
from app.models.user import User
from app.schemas.commerce import (
    OrderDisputeCreate,
    OrderDisputeResolve,
    OrderDisputeResponse,
)
from app.services import order_dispute as dispute_service

router = APIRouter()


@router.post("", response_model=OrderDisputeResponse, status_code=201)
async def open_dispute(
    body: OrderDisputeCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await dispute_service.create_dispute(db, user, body)


@router.get("/mine", response_model=list[OrderDisputeResponse])
async def my_disputes(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await dispute_service.list_my_disputes(db, user)


@router.get("/business", response_model=list[OrderDisputeResponse])
async def merchant_disputes(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await dispute_service.list_merchant_disputes(db, user)


@router.get("", response_model=list[OrderDisputeResponse])
async def list_disputes(
    status: str | None = Query(default=None),
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    _ = admin
    return await dispute_service.list_disputes(db, status=status)


@router.post("/{dispute_id}/resolve", response_model=OrderDisputeResponse)
async def resolve_dispute(
    dispute_id: UUID,
    body: OrderDisputeResolve,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    return await dispute_service.resolve_dispute(db, admin, dispute_id, body)
