from uuid import UUID

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_admin, get_current_user
from app.models.user import User
from app.schemas.marketplace import BusinessCreate, BusinessResponse, BusinessUpdate
from app.schemas.commerce import MerchantPayoutResponse
from app.services import business as business_service
from app.services import payout as payout_service

router = APIRouter()


class MerchantKycRegisterBody(BaseModel):
    owner_full_name: str = Field(min_length=2, max_length=120)
    owner_nin: str | None = Field(default=None, max_length=40)
    owner_date_of_birth: str | None = None
    tin: str | None = Field(default=None, max_length=40)


class MerchantDocumentUpload(BaseModel):
    doc_type: str = Field(min_length=3, max_length=40)
    url: str = Field(min_length=3)
    object_key: str | None = None
    mime_type: str | None = None
    meta: dict | None = None


@router.get("", response_model=list[BusinessResponse])
async def list_businesses(
    category_id: UUID | None = None,
    q: str | None = None,
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
    lat: float | None = Query(None, description="Customer latitude for nearby sort"),
    lng: float | None = Query(None, description="Customer longitude for nearby sort"),
    radius_km: float | None = Query(None, ge=0.5, le=100, description="Nearby radius km"),
    db: AsyncSession = Depends(get_db),
):
    rows, _ = await business_service.list_businesses(
        db,
        category_id=category_id,
        q=q,
        page=page,
        page_size=page_size,
        lat=lat,
        lng=lng,
        radius_km=radius_km,
    )
    return rows


@router.get("/mine", response_model=list[BusinessResponse])
async def my_businesses(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Businesses owned by the current user (must be before /{business_id})."""
    return await business_service.list_owned_businesses(db, user)


@router.get("/workplace", response_model=list[BusinessResponse])
async def workplace_businesses(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Shops this person owns or is employed by. Used for short-video publishing."""
    return await business_service.list_workplace_businesses(db, user)


@router.post("", response_model=BusinessResponse, status_code=201)
async def create_business(
    body: BusinessCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await business_service.create_business(db, user, body)


@router.get("/{business_id}/payouts", response_model=list[MerchantPayoutResponse])
async def list_business_payouts(
    business_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Owner/admin: MoMo disbursements for this business (non-custodial)."""
    return await payout_service.list_business_payouts(db, user, business_id)


@router.post("/{business_id}/kyc/register")
async def register_merchant_kyc(
    business_id: UUID,
    body: MerchantKycRegisterBody,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Owner identity for shop KYC (can collect now; enforcement is policy-gated)."""
    from app.services import merchant_verification as mv

    return await mv.register_owner_identity(
        db,
        user,
        business_id,
        owner_full_name=body.owner_full_name,
        owner_nin=body.owner_nin,
        owner_date_of_birth=body.owner_date_of_birth,
        tin=body.tin,
    )


@router.post("/{business_id}/kyc/documents")
async def upload_merchant_kyc_document(
    business_id: UUID,
    body: MerchantDocumentUpload,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    from app.services import merchant_verification as mv

    return await mv.upsert_document(
        db,
        user,
        business_id,
        doc_type=body.doc_type,
        url=body.url,
        object_key=body.object_key,
        mime_type=body.mime_type,
        meta=body.meta,
    )


@router.post("/{business_id}/kyc/submit")
async def submit_merchant_kyc(
    business_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    from app.services import merchant_verification as mv

    return await mv.submit_for_verification(db, user, business_id)


@router.get("/{business_id}/kyc")
async def get_merchant_kyc(
    business_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    from app.services import merchant_verification as mv

    return await mv.get_my_verification(db, user, business_id)


@router.get("/{business_id}", response_model=BusinessResponse)
async def get_business(business_id: UUID, db: AsyncSession = Depends(get_db)):
    return await business_service.get_business(db, business_id)


@router.patch("/{business_id}", response_model=BusinessResponse)
async def update_business(
    business_id: UUID,
    body: BusinessUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await business_service.update_business(db, user, business_id, body)


@router.post("/{business_id}/verify", response_model=BusinessResponse)
async def verify_business(
    business_id: UUID,
    status: str = "VERIFIED",
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    return await business_service.set_verification(db, admin, business_id, status)


@router.post("/{business_id}/suspend", response_model=BusinessResponse)
async def suspend_business(
    business_id: UUID,
    admin: User = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    biz = await business_service.set_verification(db, admin, business_id, "SUSPENDED")
    biz.status = "SUSPENDED"
    await db.flush()
    return biz
