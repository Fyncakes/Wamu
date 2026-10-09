from uuid import UUID

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user
from app.models.user import User
from app.schemas.commerce import (
    OrderBatchCreate,
    OrderBatchResponse,
    OrderCreate,
    OrderResponse,
    OrderStatusUpdate,
    ReceiptRevise,
)
from app.services import order as order_service

router = APIRouter()


@router.post("", response_model=OrderResponse, status_code=201)
async def create_order(
    body: OrderCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await order_service.create_order(db, user, body)


@router.post("/batch", response_model=OrderBatchResponse, status_code=201)
async def create_order_batch(
    body: OrderBatchCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Multi-shop checkout — one parent batch, one sub-order per merchant."""
    return await order_service.create_order_batch(db, user, body)


@router.patch("/{order_id}/receipt", response_model=OrderResponse)
async def revise_receipt(
    order_id: UUID,
    body: ReceiptRevise,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Merchant edits an unpaid receipt after renegotiation in chat."""
    return await order_service.revise_receipt(db, user, order_id, body)


@router.get("", response_model=list[OrderResponse])
async def my_orders(user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    return await order_service.list_customer_orders(db, user)


@router.get("/business/{business_id}", response_model=list[OrderResponse])
async def business_orders(
    business_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await order_service.list_business_orders(db, user, business_id)


@router.get("/{order_id}", response_model=OrderResponse)
async def get_order(
    order_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    order = await order_service.get_order(db, order_id)
    if order.customer_id != user.id and user.role != "ADMIN":
        # allow business members
        from app.services.business import assert_business_member

        await assert_business_member(db, user, order.business_id)
    return order


@router.patch("/{order_id}/status", response_model=OrderResponse)
async def update_status(
    order_id: UUID,
    body: OrderStatusUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await order_service.update_order_status(db, user, order_id, body)
