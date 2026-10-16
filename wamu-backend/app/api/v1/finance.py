"""Merchant + admin finance endpoints (Phase A read models + Phase B reconcile)."""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, Query
from fastapi.responses import Response
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.database import get_db
from app.core.deps import get_current_admin, get_current_user
from app.models.user import User
from app.schemas.commerce import MerchantPayoutResponse
from app.schemas.finance import (
    AdminFinanceOverview,
    ExecutePayoutQueueRequest,
    FinanceLedgerPage,
    FinanceSummaryResponse,
    OwnerPayoutRequest,
    PayoutQueueItem,
    PayoutQueuePage,
    ReconciliationRunResponse,
    ResolveSuspenseRequest,
    RunReconciliationRequest,
    StatementImportRequest,
    SuspenseItemResponse,
    SuspensePage,
)
from app.services import finance as finance_service
from app.services import payout as payout_service
from app.services import statement_reconciliation as recon_service

router = APIRouter()


@router.get(
    "/businesses/{business_id}/finance/summary",
    response_model=FinanceSummaryResponse,
)
async def business_finance_summary(
    business_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await finance_service.merchant_finance_summary(db, user, business_id)


@router.get(
    "/businesses/{business_id}/finance/ledger",
    response_model=FinanceLedgerPage,
)
async def business_finance_ledger(
    business_id: UUID,
    page: int = Query(1, ge=1),
    page_size: int = Query(50, ge=1, le=200),
    date_from: datetime | None = None,
    date_to: datetime | None = None,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await finance_service.merchant_finance_ledger(
        db,
        user,
        business_id,
        page=page,
        page_size=page_size,
        since=date_from,
        until=date_to,
    )


@router.get("/businesses/{business_id}/finance/reports")
async def business_finance_reports(
    business_id: UUID,
    report_type: str = Query("earnings"),
    format: str = Query("csv", pattern="^(csv|pdf|json)$"),
    date_from: datetime | None = None,
    date_to: datetime | None = None,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    summary = await finance_service.merchant_finance_summary(db, user, business_id)
    if format == "json":
        return {
            "summary": summary.model_dump(mode="json"),
            "report_type": report_type,
            "date_from": date_from,
            "date_to": date_to,
        }
    if format == "csv":
        body = await finance_service.merchant_report_csv(
            db,
            user,
            business_id,
            report_type=report_type,
            since=date_from,
            until=date_to,
        )
        return Response(
            content=body,
            media_type="text/csv",
            headers={
                "Content-Disposition": (
                    f'attachment; filename="wamu-{report_type}-{business_id}.csv"'
                )
            },
        )
    # PDF
    from app.services import business as business_service

    biz = await business_service.get_business(db, business_id)
    pdf = finance_service.merchant_report_pdf_bytes(
        business_name=biz.name,
        summary=summary,
        report_type=report_type,
    )
    return Response(
        content=pdf,
        media_type="application/pdf",
        headers={
            "Content-Disposition": (
                f'attachment; filename="wamu-{report_type}-{business_id}.pdf"'
            )
        },
    )


@router.get("/admin/finance/overview", response_model=AdminFinanceOverview)
async def admin_finance_overview(
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    _ = admin
    return await finance_service.admin_finance_overview(db)


@router.get("/admin/finance/ledger", response_model=FinanceLedgerPage)
async def admin_finance_ledger(
    account_type: str | None = None,
    account_id: UUID | None = None,
    source_type: str | None = None,
    date_from: datetime | None = None,
    date_to: datetime | None = None,
    page: int = Query(1, ge=1),
    page_size: int = Query(50, ge=1, le=200),
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    _ = admin
    return await finance_service.admin_finance_ledger(
        db,
        account_type=account_type,
        account_id=account_id,
        source_type=source_type,
        since=date_from,
        until=date_to,
        page=page,
        page_size=page_size,
    )


@router.post("/admin/finance/reconcile/run")
async def admin_run_reconciliation(
    body: RunReconciliationRequest | None = None,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    """Synthetic statement pull + match (Phase B — no live provider API yet)."""
    req = body or RunReconciliationRequest()
    batch = await recon_service.build_synthetic_statement(
        db,
        provider=req.provider,
        hours=req.hours,
        include_orphan=req.include_orphan,
        created_by=f"admin:{admin.id}",
    )
    run = await recon_service.match_batch(
        db, batch, created_by=f"admin:{admin.id}"
    )
    return {
        "status": "ok",
        "batch_id": str(batch.id),
        "run": ReconciliationRunResponse.model_validate(run).model_dump(mode="json"),
    }


@router.post("/admin/finance/reconcile/import")
async def admin_import_statement(
    body: StatementImportRequest,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    lines = [line.model_dump(mode="json") for line in body.lines]
    batch = await recon_service.import_statement_lines(
        db,
        provider=body.provider,
        lines=lines,
        source="import",
        created_by=f"admin:{admin.id}",
        notes=body.notes,
    )
    run = await recon_service.match_batch(
        db, batch, created_by=f"admin:{admin.id}"
    )
    return {
        "status": "ok",
        "batch_id": str(batch.id),
        "run": ReconciliationRunResponse.model_validate(run).model_dump(mode="json"),
    }


@router.get("/admin/finance/suspense", response_model=SuspensePage)
async def admin_list_suspense(
    status: str | None = Query("OPEN"),
    page: int = Query(1, ge=1),
    page_size: int = Query(50, ge=1, le=200),
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    _ = admin
    rows, total = await recon_service.list_suspense(
        db, status=status, page=page, page_size=page_size
    )
    return SuspensePage(
        items=[SuspenseItemResponse.model_validate(r) for r in rows],
        total=total,
        page=page,
        page_size=page_size,
    )


@router.post(
    "/admin/finance/suspense/{suspense_id}/resolve",
    response_model=SuspenseItemResponse,
)
async def admin_resolve_suspense(
    suspense_id: UUID,
    body: ResolveSuspenseRequest,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    item = await recon_service.resolve_suspense(
        db,
        admin,
        suspense_id,
        notes=body.notes,
        action=body.action,
    )
    return SuspenseItemResponse.model_validate(item)


@router.get("/admin/finance/payout-queue", response_model=PayoutQueuePage)
async def admin_payout_queue(
    page: int = Query(1, ge=1),
    page_size: int = Query(50, ge=1, le=200),
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    _ = admin
    rows, total = await recon_service.list_payout_queue(
        db, page=page, page_size=page_size
    )
    return PayoutQueuePage(
        items=[PayoutQueueItem.model_validate(r) for r in rows],
        total=total,
        page=page,
        page_size=page_size,
        auto_execute=get_settings().payout_auto_execute,
    )


@router.post("/admin/finance/payout-queue/execute")
async def admin_execute_payout_queue(
    body: ExecutePayoutQueueRequest | None = None,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    """Phase C — batch-execute the payout queue (register before /{id}/execute)."""
    req = body or ExecutePayoutQueueRequest()
    summary = await payout_service.execute_payout_queue(
        db,
        admin,
        limit=req.limit,
        payout_ids=req.payout_ids,
    )
    return {"status": "ok", **summary}


@router.post(
    "/admin/finance/payout-queue/{payout_id}/execute",
    response_model=MerchantPayoutResponse,
)
async def admin_execute_payout(
    payout_id: UUID,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    """Phase C — disburse one queued/failed payout (ignores PAYOUT_AUTO_EXECUTE)."""
    return await payout_service.execute_payout(db, admin, payout_id)


@router.get("/admin/finance/rider-payout-queue")
async def admin_rider_payout_queue(
    page: int = Query(1, ge=1),
    page_size: int = Query(50, ge=1, le=200),
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    _ = admin
    from app.services import rider_payout as rider_svc

    rows, total = await rider_svc.list_rider_payout_queue(
        db, page=page, page_size=page_size
    )
    return {
        "items": [
            {
                "id": str(r.id),
                "delivery_id": str(r.delivery_id),
                "order_id": str(r.order_id),
                "rider_id": str(r.rider_id),
                "amount": float(r.amount),
                "currency": r.currency,
                "provider": r.provider,
                "payee_phone": r.payee_phone,
                "status": r.status,
                "created_at": r.created_at.isoformat() if r.created_at else None,
            }
            for r in rows
        ],
        "total": total,
        "page": page,
        "page_size": page_size,
    }


@router.post("/admin/finance/rider-payout-queue/{payout_id}/execute")
async def admin_execute_rider_payout(
    payout_id: UUID,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    from app.services import rider_payout as rider_svc

    p = await rider_svc.execute_rider_payout(db, admin, payout_id)
    return {"id": str(p.id), "status": p.status, "amount": float(p.amount)}


@router.get("/admin/finance/owner-payouts")
async def admin_owner_payouts(
    page: int = Query(1, ge=1),
    page_size: int = Query(50, ge=1, le=200),
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    _ = admin
    from app.services import owner_payout as owner_svc

    available = await owner_svc.available_commission_minor(db)
    rows, total = await owner_svc.list_owner_payouts(
        db, page=page, page_size=page_size
    )
    return {
        "available_commission_minor": available,
        "owner_payout_phone_set": bool(get_settings().owner_payout_phone),
        "items": [
            {
                "id": str(r.id),
                "amount": float(r.amount),
                "amount_minor": r.amount_minor,
                "currency": r.currency,
                "provider": r.provider,
                "payee_phone": r.payee_phone,
                "status": r.status,
                "notes": r.notes,
                "created_at": r.created_at.isoformat() if r.created_at else None,
            }
            for r in rows
        ],
        "total": total,
        "page": page,
        "page_size": page_size,
    }


@router.post("/admin/finance/owner-payouts/request")
async def admin_request_owner_payout(
    body: OwnerPayoutRequest | None = None,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    from app.services import owner_payout as owner_svc

    req = body or OwnerPayoutRequest()
    p = await owner_svc.request_owner_payout(
        db,
        admin,
        amount_minor=req.amount_minor,
        notes=req.notes,
        idempotency_key=req.idempotency_key,
    )
    return {
        "id": str(p.id),
        "status": p.status,
        "amount_minor": p.amount_minor,
        "payee_phone": p.payee_phone,
    }


@router.post("/admin/finance/owner-payouts/{payout_id}/execute")
async def admin_execute_owner_payout(
    payout_id: UUID,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    from app.services import owner_payout as owner_svc

    p = await owner_svc.execute_owner_payout(db, admin, payout_id)
    return {"id": str(p.id), "status": p.status, "amount_minor": p.amount_minor}


@router.get("/admin/finance/manual-refunds")
async def admin_manual_refunds(
    page: int = Query(1, ge=1),
    page_size: int = Query(50, ge=1, le=200),
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    """Payments where MoMo reverse failed — ops must refund in provider portal."""
    _ = admin
    from sqlalchemy import select

    from app.models.payment import Payment, PaymentStatus

    q = (
        select(Payment)
        .where(Payment.status == PaymentStatus.REFUNDED.value)
        .order_by(Payment.created_at.desc())
    )
    rows = list((await db.scalars(q.limit(500))).all())
    manual = []
    for p in rows:
        refund = (p.raw_response or {}).get("refund") or {}
        if refund.get("manual_required"):
            manual.append(p)
    total = len(manual)
    start = (page - 1) * page_size
    page_rows = manual[start : start + page_size]
    return {
        "items": [
            {
                "id": str(p.id),
                "order_id": str(p.order_id),
                "amount": float(p.amount),
                "currency": p.currency,
                "provider": p.provider,
                "provider_reference": p.provider_reference,
                "refund": (p.raw_response or {}).get("refund"),
                "created_at": p.created_at.isoformat() if p.created_at else None,
            }
            for p in page_rows
        ],
        "total": total,
        "page": page,
        "page_size": page_size,
    }
