"""Order dispute service — open by customer, resolve by admin."""

from __future__ import annotations

import uuid
from datetime import datetime, timezone

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.notification import Notification
from app.models.order import Order, OrderStatus
from app.models.order_dispute import DisputeReason, DisputeStatus, OrderDispute
from app.models.payment import Payment, PaymentStatus
from app.models.user import User
from app.schemas.commerce import OrderDisputeCreate, OrderDisputeResolve


ALLOWED_REASONS = {r.value for r in DisputeReason}
RESOLVE_STATUSES = {
    DisputeStatus.RESOLVED_REFUND.value,
    DisputeStatus.RESOLVED_REJECT.value,
    DisputeStatus.DISMISSED.value,
}
DISPUTABLE_ORDER = {
    OrderStatus.DELIVERED.value,
    OrderStatus.OUT_FOR_DELIVERY.value,
}


async def create_dispute(
    db: AsyncSession, user: User, data: OrderDisputeCreate
) -> OrderDispute:
    reason = (data.reason or "").upper().strip()
    if reason not in ALLOWED_REASONS:
        raise HTTPException(
            status_code=400,
            detail=f"reason must be one of {sorted(ALLOWED_REASONS)}",
        )

    order = await db.get(Order, data.order_id)
    if not order:
        raise HTTPException(status_code=404, detail="Order not found")
    if order.customer_id != user.id:
        raise HTTPException(status_code=403, detail="Not your order")
    if order.status not in DISPUTABLE_ORDER:
        raise HTTPException(
            status_code=400,
            detail="Disputes allowed after delivery starts (OUT_FOR_DELIVERY / DELIVERED)",
        )

    payment = await db.scalar(select(Payment).where(Payment.order_id == order.id))
    if payment is None or payment.status != PaymentStatus.SUCCESS.value:
        raise HTTPException(status_code=400, detail="Order is not paid")

    existing = await db.scalar(
        select(OrderDispute).where(
            OrderDispute.order_id == order.id,
            OrderDispute.status == DisputeStatus.OPEN.value,
        )
    )
    if existing:
        raise HTTPException(status_code=409, detail="Open dispute already exists for this order")

    dispute = OrderDispute(
        order_id=order.id,
        customer_id=user.id,
        reason=reason,
        description=(data.description or "").strip() or None,
        status=DisputeStatus.OPEN.value,
    )
    db.add(dispute)
    await db.flush()

    # Notify business owner
    from app.models.business import Business

    biz = await db.get(Business, order.business_id)
    if biz:
        db.add(
            Notification(
                user_id=biz.owner_id,
                type="ORDER_DISPUTE",
                title="Order dispute opened",
                body=f"Customer disputed order ({reason})",
                data={
                    "order_id": str(order.id),
                    "dispute_id": str(dispute.id),
                    "audience": "merchant",
                },
            )
        )
    await db.flush()
    await db.refresh(dispute)
    return dispute


async def list_disputes(
    db: AsyncSession, *, status: str | None = None, limit: int = 100
) -> list[OrderDispute]:
    q = select(OrderDispute).order_by(OrderDispute.created_at.desc()).limit(limit)
    if status:
        q = q.where(OrderDispute.status == status.upper())
    result = await db.execute(q)
    return list(result.scalars().all())


async def list_my_disputes(db: AsyncSession, user: User) -> list[OrderDispute]:
    result = await db.execute(
        select(OrderDispute)
        .where(OrderDispute.customer_id == user.id)
        .order_by(OrderDispute.created_at.desc())
        .limit(50)
    )
    return list(result.scalars().all())


async def list_merchant_disputes(db: AsyncSession, user: User) -> list[OrderDispute]:
    """Disputes on orders for businesses the user owns or manages."""
    from app.models.business import Business, BusinessMember

    owned = select(Business.id).where(Business.owner_id == user.id)
    member = select(BusinessMember.business_id).where(BusinessMember.user_id == user.id)
    biz_ids = owned.union(member)
    result = await db.execute(
        select(OrderDispute)
        .join(Order, Order.id == OrderDispute.order_id)
        .where(Order.business_id.in_(biz_ids))
        .order_by(OrderDispute.created_at.desc())
        .limit(50)
    )
    return list(result.scalars().all())


async def resolve_dispute(
    db: AsyncSession, admin: User, dispute_id: uuid.UUID, data: OrderDisputeResolve
) -> OrderDispute:
    dispute = await db.get(OrderDispute, dispute_id)
    if not dispute:
        raise HTTPException(status_code=404, detail="Dispute not found")
    if dispute.status != DisputeStatus.OPEN.value:
        raise HTTPException(status_code=400, detail="Dispute already resolved")

    new_status = (data.status or "").upper().strip()
    if new_status not in RESOLVE_STATUSES:
        raise HTTPException(
            status_code=400,
            detail=f"status must be one of {sorted(RESOLVE_STATUSES)}",
        )

    dispute.status = new_status
    dispute.resolution_note = (data.resolution_note or "").strip() or None
    dispute.resolved_by_id = admin.id
    dispute.resolved_at = datetime.now(timezone.utc)

    order = await db.scalar(
        select(Order)
        .options(selectinload(Order.items))
        .where(Order.id == dispute.order_id)
    )
    if order and new_status == DisputeStatus.RESOLVED_REFUND.value:
        from app.services.order import restock_order
        from app.services.payout import reverse_payout_for_payment

        if order.status == OrderStatus.DELIVERED.value:
            order.status = OrderStatus.REFUNDED.value
            order.version += 1
        payment = await db.scalar(select(Payment).where(Payment.order_id == order.id))
        if payment and payment.status == PaymentStatus.SUCCESS.value:
            await restock_order(db, order)
            from app.services.payment import attempt_collection_refund

            await attempt_collection_refund(db, payment, reason="dispute_refund")
            await reverse_payout_for_payment(db, payment, reason="dispute_refund")

    db.add(
        Notification(
            user_id=dispute.customer_id,
            type="ORDER_DISPUTE",
            title="Dispute update",
            body=f"Your dispute is now {new_status.replace('_', ' ').title()}",
            data={
                "order_id": str(dispute.order_id),
                "dispute_id": str(dispute.id),
                "status": new_status,
                "audience": "customer",
            },
        )
    )
    await db.flush()
    await db.refresh(dispute)
    return dispute
