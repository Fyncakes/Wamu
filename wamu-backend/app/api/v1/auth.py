from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user
from app.core.media_urls import public_origin
from app.core.rate_limit import is_rate_limited
from app.core.config import get_settings
from app.models.user import User
from app.schemas.auth import (
    DeviceLinkClaimRequest,
    DeviceLinkCreateResponse,
    DeviceLinkStatusResponse,
    OtpVerifyRequest,
    PhoneRequest,
    RefreshRequest,
    TokenResponse,
)
from app.services import auth as auth_service

router = APIRouter()
settings = get_settings()


@router.post("/request-otp")
async def request_otp(body: PhoneRequest, request: Request, db: AsyncSession = Depends(get_db)):
    # Tunnel demos share one egress IP — skip IP throttle in mock OTP mode.
    if not settings.otp_mock_mode:
        ip = request.client.host if request.client else "unknown"
        if await is_rate_limited(f"otp-ip:{ip}", settings.rate_limit_otp_per_hour * 3, 3600):
            from fastapi import HTTPException

            raise HTTPException(status_code=429, detail="Too many OTP requests from this IP")
    return await auth_service.request_otp(db, body.phone)


@router.post("/verify-otp", response_model=TokenResponse)
async def verify_otp(
    body: OtpVerifyRequest, request: Request, db: AsyncSession = Depends(get_db)
):
    ip = request.client.host if request.client else None
    return await auth_service.verify_otp(
        db,
        phone=body.phone,
        code=body.code,
        device_name=body.device_name,
        device_id=body.device_id,
        ip_address=ip,
    )


@router.post("/refresh", response_model=TokenResponse)
async def refresh(body: RefreshRequest, db: AsyncSession = Depends(get_db)):
    return await auth_service.refresh_tokens(db, body.refresh_token)


@router.post("/device-link", response_model=DeviceLinkCreateResponse)
async def create_device_link(
    request: Request,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    if await is_rate_limited(f"device-link:{user.id}", 20, 3600):
        raise HTTPException(status_code=429, detail="Too many QR codes. Try again later.")
    return await auth_service.create_device_link(
        db, user=user, origin=public_origin(request)
    )


@router.post("/device-link/revoke")
async def revoke_device_links(
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    await auth_service.revoke_device_links(db, user=user)
    return {"ok": True}


@router.post("/device-link/claim", response_model=TokenResponse)
async def claim_device_link(
    body: DeviceLinkClaimRequest,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    ip = request.client.host if request.client else "unknown"
    if await is_rate_limited(f"device-link-claim:{ip}", 30, 3600):
        raise HTTPException(status_code=429, detail="Too many attempts. Try later.")
    return await auth_service.claim_device_link(
        db,
        token=body.token,
        device_name=body.device_name,
        device_id=body.device_id,
        ip_address=ip,
    )


@router.get("/device-link/{link_id}", response_model=DeviceLinkStatusResponse)
async def device_link_status(
    link_id: UUID,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    return await auth_service.device_link_status(db, user=user, link_id=link_id)
