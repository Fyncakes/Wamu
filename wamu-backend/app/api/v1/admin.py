"""Normalize admin list responses for clients that expect either arrays or {items:[]}."""

from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.database import get_db
from app.core.deps import get_current_admin
from app.models.business import Business, Category
from app.models.order import Order
from app.models.order_dispute import DisputeStatus, OrderDispute
from app.models.payment import Payment, PaymentStatus
from app.models.payout import MerchantPayout, PayoutStatus
from app.models.report import Report
from app.models.rider import RiderProfile, RiderStatus
from app.models.user import User
from app.schemas.auth import UserResponse
from app.schemas.commerce import (
    AdminStats,
    MerchantPayoutResponse,
    OrderDisputeResolve,
    OrderDisputeResponse,
    OrderResponse,
    PaymentResponse,
    ReportResolve,
    ReportResponse,
)
from app.schemas.marketplace import BusinessResponse, CategoryResponse
from app.services import business as business_service
from app.services import order_dispute as dispute_service
from app.services import payout as payout_service
from app.services import social as social_service

router = APIRouter()


def _money(value) -> float:
    if value is None:
        return 0.0
    return float(value)


@router.get("/stats", response_model=AdminStats)
async def stats(admin: User = Depends(get_current_admin), db: AsyncSession = Depends(get_db)):
    _ = admin
    users = await db.scalar(select(func.count()).select_from(User)) or 0
    businesses = await db.scalar(select(func.count()).select_from(Business)) or 0
    orders = await db.scalar(select(func.count()).select_from(Order)) or 0
    payments = await db.scalar(select(func.count()).select_from(Payment)) or 0
    open_reports = (
        await db.scalar(select(func.count()).select_from(Report).where(Report.status == "OPEN"))
        or 0
    )
    open_disputes = (
        await db.scalar(
            select(func.count())
            .select_from(OrderDispute)
            .where(OrderDispute.status == DisputeStatus.OPEN.value)
        )
        or 0
    )
    pending = (
        await db.scalar(
            select(func.count())
            .select_from(Business)
            .where(Business.verification_status == "PENDING")
        )
        or 0
    )
    revenue = await db.scalar(
        select(func.coalesce(func.sum(Payment.amount), 0)).where(
            Payment.status == PaymentStatus.SUCCESS.value
        )
    )
    fee_total = await db.scalar(
        select(func.coalesce(func.sum(MerchantPayout.platform_fee), 0)).where(
            MerchantPayout.status == PayoutStatus.SUCCESS.value
        )
    )
    payout_net = await db.scalar(
        select(func.coalesce(func.sum(MerchantPayout.amount), 0)).where(
            MerchantPayout.status == PayoutStatus.SUCCESS.value
        )
    )
    successful_payouts = (
        await db.scalar(
            select(func.count())
            .select_from(MerchantPayout)
            .where(MerchantPayout.status == PayoutStatus.SUCCESS.value)
        )
        or 0
    )
    order_rows = await db.execute(
        select(Order.status, func.count()).group_by(Order.status)
    )
    orders_by_status = {str(status): int(count) for status, count in order_rows.all()}
    payment_rows = await db.execute(
        select(Payment.status, func.count()).group_by(Payment.status)
    )
    payments_by_status = {
        str(status): int(count) for status, count in payment_rows.all()
    }
    riders_total = (
        await db.scalar(
            select(func.count())
            .select_from(RiderProfile)
            .where(RiderProfile.deleted_at.is_(None))
        )
        or 0
    )
    riders_approved = (
        await db.scalar(
            select(func.count())
            .select_from(RiderProfile)
            .where(
                RiderProfile.deleted_at.is_(None),
                RiderProfile.status == RiderStatus.APPROVED.value,
            )
        )
        or 0
    )
    riders_pending = (
        await db.scalar(
            select(func.count())
            .select_from(RiderProfile)
            .where(
                RiderProfile.deleted_at.is_(None),
                RiderProfile.status.in_(
                    (
                        RiderStatus.DRAFT.value,
                        RiderStatus.SUBMITTED.value,
                        RiderStatus.UNDER_REVIEW.value,
                        RiderStatus.NEEDS_REUPLOAD.value,
                    )
                ),
            )
        )
        or 0
    )
    return AdminStats(
        users=int(users),
        businesses=int(businesses),
        orders=int(orders),
        payments=int(payments),
        riders=int(riders_total),
        riders_approved=int(riders_approved),
        riders_pending=int(riders_pending),
        open_reports=int(open_reports),
        open_disputes=int(open_disputes),
        pending_verifications=int(pending),
        revenue_ugx=_money(revenue),
        platform_fee_ugx=_money(fee_total),
        payout_net_ugx=_money(payout_net),
        successful_payouts=int(successful_payouts),
        orders_by_status=orders_by_status,
        payments_by_status=payments_by_status,
    )


def _wrap(items: list) -> dict:
    return {"items": items, "total": len(items), "page": 1, "page_size": len(items)}


@router.post("/users/{user_id}/suspend")
async def admin_suspend_user(
    user_id: UUID,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    from app.services import trust as trust_service

    user = await trust_service.admin_set_user_status(db, admin, user_id, "SUSPENDED")
    return UserResponse.model_validate(user)


@router.post("/users/{user_id}/activate")
async def admin_activate_user(
    user_id: UUID,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    from app.services import trust as trust_service

    user = await trust_service.admin_set_user_status(db, admin, user_id, "ACTIVE")
    return UserResponse.model_validate(user)


@router.get("/users")
async def admin_users(admin: User = Depends(get_current_admin), db: AsyncSession = Depends(get_db)):
    _ = admin
    result = await db.execute(
        select(User).options(selectinload(User.profile)).order_by(User.created_at.desc()).limit(200)
    )
    users = [UserResponse.model_validate(u).model_dump(mode="json") for u in result.scalars()]
    return _wrap(users)


@router.get("/businesses")
async def admin_businesses(
    admin: User = Depends(get_current_admin), db: AsyncSession = Depends(get_db)
):
    _ = admin
    result = await db.execute(
        select(Business)
        .options(selectinload(Business.location))
        .order_by(Business.created_at.desc())
        .limit(200)
    )
    rows = [BusinessResponse.model_validate(b).model_dump(mode="json") for b in result.scalars()]
    return _wrap(rows)


@router.post("/businesses/{business_id}/verify")
async def admin_verify(
    business_id: UUID,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    biz = await business_service.set_verification(db, admin, business_id, "VERIFIED")
    return BusinessResponse.model_validate(biz)


@router.post("/businesses/{business_id}/suspend")
async def admin_suspend(
    business_id: UUID,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    biz = await business_service.set_verification(db, admin, business_id, "SUSPENDED")
    biz.status = "SUSPENDED"
    await db.flush()
    return BusinessResponse.model_validate(biz)


@router.get("/orders")
async def admin_orders(admin: User = Depends(get_current_admin), db: AsyncSession = Depends(get_db)):
    _ = admin
    result = await db.execute(
        select(Order)
        .options(selectinload(Order.items), selectinload(Order.payment))
        .order_by(Order.created_at.desc())
        .limit(200)
    )
    rows = []
    for o in result.scalars():
        data = OrderResponse.model_validate(o).model_dump(mode="json")
        data["total_amount"] = data["total"]  # admin UI alias
        rows.append(data)
    return _wrap(rows)


@router.get("/payments")
async def admin_payments(
    admin: User = Depends(get_current_admin), db: AsyncSession = Depends(get_db)
):
    _ = admin
    result = await db.execute(select(Payment).order_by(Payment.created_at.desc()).limit(200))
    rows = [PaymentResponse.model_validate(p).model_dump(mode="json") for p in result.scalars()]
    return _wrap(rows)


@router.post("/payments/reconcile")
async def admin_reconcile_payments(
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    """Run payment reconciliation now (also scheduled every 5m via Celery Beat)."""
    _ = admin
    from app.services.reconciliation import reconcile_pending_payments
    from app.workers.tasks import reconcile_payments as reconcile_task

    # Prefer async path in-request for immediate admin feedback
    summary = await reconcile_pending_payments(db, stale_hours=24, limit=100)
    # Also enqueue background tick for workers that share Redis
    try:
        reconcile_task.delay(stale_hours=24, limit=100)
    except Exception:
        pass
    return {"status": "ok", **summary}


@router.get("/payouts")
async def admin_payouts(
    admin: User = Depends(get_current_admin), db: AsyncSession = Depends(get_db)
):
    _ = admin
    result = await db.execute(
        select(MerchantPayout).order_by(MerchantPayout.created_at.desc()).limit(200)
    )
    rows = [
        MerchantPayoutResponse.model_validate(p).model_dump(mode="json") for p in result.scalars()
    ]
    return _wrap(rows)


@router.post("/payouts/reconcile")
async def admin_reconcile_payouts(
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    _ = admin
    from app.workers.tasks import reconcile_payouts as reconcile_task

    summary = await payout_service.reconcile_pending_payouts(db, stale_hours=24, limit=100)
    try:
        reconcile_task.delay(stale_hours=24, limit=100)
    except Exception:
        pass
    return {"status": "ok", **summary}


@router.post("/payouts/{payout_id}/retry", response_model=MerchantPayoutResponse)
async def admin_retry_payout(
    payout_id: UUID,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    return await payout_service.retry_payout(db, admin, payout_id)


@router.get("/categories")
async def admin_categories(
    admin: User = Depends(get_current_admin), db: AsyncSession = Depends(get_db)
):
    _ = admin
    result = await db.execute(select(Category).order_by(Category.name))
    rows = [CategoryResponse.model_validate(c).model_dump(mode="json") for c in result.scalars()]
    return _wrap(rows)


@router.get("/reports")
async def admin_reports(admin: User = Depends(get_current_admin), db: AsyncSession = Depends(get_db)):
    _ = admin
    result = await db.execute(select(Report).order_by(Report.created_at.desc()).limit(200))
    rows = [ReportResponse.model_validate(r).model_dump(mode="json") for r in result.scalars()]
    return _wrap(rows)


@router.post("/reports/{report_id}/resolve")
async def admin_resolve_report(
    report_id: UUID,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    return await social_service.resolve_report(
        db, admin, report_id, ReportResolve(status="RESOLVED", resolution_note="Resolved by admin")
    )


@router.get("/disputes")
async def admin_disputes(
    status: str | None = None,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    _ = admin
    rows = await dispute_service.list_disputes(db, status=status)
    return _wrap(
        [OrderDisputeResponse.model_validate(r).model_dump(mode="json") for r in rows]
    )


@router.post("/disputes/{dispute_id}/resolve", response_model=OrderDisputeResponse)
async def admin_resolve_dispute(
    dispute_id: UUID,
    body: OrderDisputeResolve,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    return await dispute_service.resolve_dispute(db, admin, dispute_id, body)


@router.get("/riders")
async def admin_riders(
    status: str | None = None,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    _ = admin
    from app.services import dashboards as dash

    return _wrap(await dash.admin_list_riders(db, status=status))


class RiderModerationBody(BaseModel):
    note: str | None = Field(default=None, max_length=500)
    reupload_fields: list[str] | None = None


@router.get("/riders/verification-queue")
async def admin_rider_verification_queue(
    status: str | None = "QUEUE",
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    _ = admin
    from app.services import rider_verification as rv

    return _wrap(await rv.admin_verification_queue(db, status=status))


@router.get("/riders/{rider_id}")
async def admin_rider_detail(
    rider_id: UUID,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    _ = admin
    from app.services import dashboards as dash

    return await dash.admin_rider_detail(db, rider_id)


@router.get("/riders/{rider_id}/verification")
async def admin_rider_verification_detail(
    rider_id: UUID,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    _ = admin
    from app.services import rider_verification as rv

    return await rv.admin_verification_detail(db, rider_id)


@router.post("/riders/{rider_id}/approve")
async def admin_approve_rider(
    rider_id: UUID,
    body: RiderModerationBody | None = None,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    from app.services import dashboards as dash

    return await dash.admin_set_rider_status(
        db, admin, rider_id, action="APPROVE", note=(body.note if body else None)
    )


@router.post("/riders/{rider_id}/suspend")
async def admin_suspend_rider(
    rider_id: UUID,
    body: RiderModerationBody | None = None,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    from app.services import dashboards as dash

    return await dash.admin_set_rider_status(
        db, admin, rider_id, action="SUSPEND", note=(body.note if body else None)
    )


@router.post("/riders/{rider_id}/reject")
async def admin_reject_rider(
    rider_id: UUID,
    body: RiderModerationBody | None = None,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    from app.services import dashboards as dash

    return await dash.admin_set_rider_status(
        db, admin, rider_id, action="REJECT", note=(body.note if body else None)
    )


@router.post("/riders/{rider_id}/request-reupload")
async def admin_request_rider_reupload(
    rider_id: UUID,
    body: RiderModerationBody | None = None,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    from app.services import dashboards as dash

    return await dash.admin_set_rider_status(
        db,
        admin,
        rider_id,
        action="REQUEST_REUPLOAD",
        note=(body.note if body else None),
        reupload_fields=(body.reupload_fields if body else None),
    )


@router.get("/deliveries")
async def admin_deliveries(
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    _ = admin
    from app.services import dashboards as dash

    return _wrap(await dash.admin_list_deliveries(db))


@router.get("/audit-logs")
async def admin_audit_logs(
    limit: int = 100,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    _ = admin
    from app.services import dashboards as dash

    return _wrap(await dash.admin_audit_logs(db, limit=limit))


@router.get("/fraud")
async def admin_fraud(
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    _ = admin
    from app.services import dashboards as dash

    return await dash.admin_fraud_signals(db)


@router.get("/notifications")
async def admin_notifications(
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    _ = admin
    from app.services import dashboards as dash

    return _wrap(await dash.admin_recent_notifications(db))


class BroadcastBody(BaseModel):
    title: str = Field(min_length=2, max_length=120)
    body: str = Field(min_length=2, max_length=500)
    audience: str = Field(default="ALL", max_length=20)


@router.post("/notifications/broadcast")
async def admin_broadcast(
    body: BroadcastBody,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    from app.services import dashboards as dash

    return await dash.admin_broadcast(
        db, admin, title=body.title, body=body.body, audience=body.audience
    )


@router.get("/settings/video-retention")
async def get_video_retention(
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    """Active → Archived → Permanently deleted (age-based, not engagement-based)."""
    _ = admin
    from app.services import app_settings as settings_service

    return await settings_service.get_video_retention(db)


@router.put("/settings/video-retention")
async def put_video_retention(
    body: dict,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    _ = admin
    from app.schemas.discover import VideoRetentionSettings
    from app.services import app_settings as settings_service

    parsed = VideoRetentionSettings.model_validate(body)
    return await settings_service.set_video_retention(
        db,
        archive_after_days=parsed.archive_after_days,
        purge_after_days=parsed.purge_after_days,
    )


@router.post("/videos/lifecycle/run")
async def run_video_lifecycle(
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    """Manually run archive/purge (also scheduled nightly via Celery)."""
    _ = admin
    from app.services import discover as discover_service

    return await discover_service.run_video_lifecycle(db)
