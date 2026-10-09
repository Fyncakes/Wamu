from uuid import UUID

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_admin, get_current_user
from app.models.report import Report
from app.models.user import User
from app.schemas.commerce import ReportCreate, ReportResolve, ReportResponse
from app.services import social as social_service

router = APIRouter()


@router.post("", response_model=ReportResponse, status_code=201)
async def create_report(
    body: ReportCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await social_service.create_report(db, user, body)


@router.get("", response_model=list[ReportResponse])
async def list_reports(
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(select(Report).order_by(Report.created_at.desc()).limit(200))
    return list(result.scalars().all())


@router.post("/{report_id}/resolve", response_model=ReportResponse)
async def resolve(
    report_id: UUID,
    body: ReportResolve,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    return await social_service.resolve_report(db, admin, report_id, body)
