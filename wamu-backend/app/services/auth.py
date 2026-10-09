"""Auth service: OTP request/verify, JWT + refresh sessions."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from urllib.parse import parse_qs, urlparse
from uuid import UUID

from fastapi import HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.config import get_settings
from app.core.rate_limit import is_rate_limited
from app.core.security import (
    create_access_token,
    generate_otp,
    generate_refresh_token,
    hash_token,
)
from app.integrations.sms.provider import get_sms_provider
from app.models.user import DeviceLinkChallenge, OtpChallenge, Session, User, UserProfile, UserRole
from app.schemas.auth import (
    DeviceLinkCreateResponse,
    DeviceLinkStatusResponse,
    TokenResponse,
    UserResponse,
)

settings = get_settings()


async def request_otp(db: AsyncSession, phone: str) -> dict:
    # Mock/dev: do not throttle demo chips — tunnel shares one public IP.
    if not settings.otp_mock_mode and await is_rate_limited(
        f"otp:{phone}", settings.rate_limit_otp_per_hour, 3600
    ):
        raise HTTPException(status_code=429, detail="Too many OTP requests. Try later.")

    code = settings.otp_mock_code if settings.otp_mock_mode else generate_otp()
    challenge = OtpChallenge(
        phone=phone,
        code_hash=hash_token(code),
        expires_at=datetime.now(timezone.utc) + timedelta(seconds=settings.otp_expire_seconds),
    )
    db.add(challenge)
    await db.flush()
    try:
        await get_sms_provider().send_otp(phone, code)
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    return {
        "message": "OTP sent",
        "expires_in": settings.otp_expire_seconds,
        "mock_hint": code if settings.otp_mock_mode else None,
    }


async def verify_otp(
    db: AsyncSession,
    *,
    phone: str,
    code: str,
    device_name: str | None,
    device_id: str | None,
    ip_address: str | None = None,
) -> TokenResponse:
    result = await db.execute(
        select(OtpChallenge)
        .where(
            OtpChallenge.phone == phone,
            OtpChallenge.consumed_at.is_(None),
        )
        .order_by(OtpChallenge.created_at.desc())
        .limit(1)
    )
    challenge = result.scalar_one_or_none()
    if challenge is None:
        raise HTTPException(status_code=400, detail="No OTP requested")
    now = datetime.now(timezone.utc)
    expires = challenge.expires_at
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=timezone.utc)
    if expires < now:
        raise HTTPException(status_code=400, detail="OTP expired")
    if challenge.attempts >= 5:
        raise HTTPException(status_code=400, detail="Too many attempts")

    challenge.attempts += 1
    if hash_token(code) != challenge.code_hash:
        if not (settings.otp_mock_mode and code == settings.otp_mock_code):
            await db.flush()
            raise HTTPException(status_code=400, detail="Invalid OTP")

    challenge.consumed_at = datetime.now(timezone.utc)

    user_result = await db.execute(
        select(User).options(selectinload(User.profile)).where(User.phone == phone)
    )
    user = user_result.scalar_one_or_none()
    is_new = False
    if user is None:
        is_new = True
        role = UserRole.ADMIN.value if phone == settings.admin_bootstrap_phone else UserRole.CUSTOMER.value
        user = User(phone=phone, phone_verified=True, role=role)
        db.add(user)
        await db.flush()
        db.add(UserProfile(user_id=user.id))
        await db.flush()
        await db.refresh(user, attribute_names=["profile"])
    else:
        user.phone_verified = True

    return await issue_session(
        db,
        user,
        device_name=device_name,
        device_id=device_id,
        ip_address=ip_address,
        is_new_user=is_new,
    )


async def issue_session(
    db: AsyncSession,
    user: User,
    *,
    device_name: str | None,
    device_id: str | None,
    ip_address: str | None = None,
    is_new_user: bool = False,
) -> TokenResponse:
    refresh = generate_refresh_token()
    session = Session(
        user_id=user.id,
        refresh_token_hash=hash_token(refresh),
        device_name=device_name,
        device_id=device_id,
        ip_address=ip_address,
        expires_at=datetime.now(timezone.utc)
        + timedelta(days=settings.refresh_token_expire_days),
    )
    db.add(session)
    await db.flush()
    if user.profile is None:
        await db.refresh(user, attribute_names=["profile"])
    return TokenResponse(
        access_token=create_access_token(user.id, role=user.role),
        refresh_token=refresh,
        is_new_user=is_new_user,
        user=UserResponse.model_validate(user),
    )


async def refresh_tokens(db: AsyncSession, refresh_token: str) -> TokenResponse:
    token_hash = hash_token(refresh_token)
    result = await db.execute(
        select(Session)
        .where(Session.refresh_token_hash == token_hash, Session.revoked_at.is_(None))
        .options(selectinload(Session.user).selectinload(User.profile))
    )
    session = result.scalar_one_or_none()
    expires = session.expires_at if session else None
    if expires is not None and expires.tzinfo is None:
        expires = expires.replace(tzinfo=timezone.utc)
    if session is None or expires is None or expires < datetime.now(timezone.utc):
        raise HTTPException(status_code=401, detail="Invalid refresh token")

    user = session.user
    # Rotate refresh token
    session.revoked_at = datetime.now(timezone.utc)
    new_refresh = generate_refresh_token()
    db.add(
        Session(
            user_id=user.id,
            refresh_token_hash=hash_token(new_refresh),
            device_name=session.device_name,
            device_id=session.device_id,
            expires_at=datetime.now(timezone.utc)
            + timedelta(days=settings.refresh_token_expire_days),
        )
    )
    await db.flush()
    return TokenResponse(
        access_token=create_access_token(user.id, role=user.role),
        refresh_token=new_refresh,
        user=UserResponse.model_validate(user),
    )


def _aware(dt: datetime) -> datetime:
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt


def extract_device_link_token(raw: str) -> str:
    s = (raw or "").strip()
    if not s:
        raise HTTPException(status_code=400, detail="This code is invalid or expired")
    parsed = urlparse(s)
    qs = parse_qs(parsed.query)
    if qs.get("k"):
        return qs["k"][0].strip()
    if parsed.scheme in {"http", "https", "wamu"}:
        raise HTTPException(status_code=400, detail="This code is invalid or expired")
    return s


async def create_device_link(
    db: AsyncSession, *, user: User, origin: str
) -> DeviceLinkCreateResponse:
    now = datetime.now(timezone.utc)
    existing = await db.execute(
        select(DeviceLinkChallenge).where(
            DeviceLinkChallenge.user_id == user.id,
            DeviceLinkChallenge.consumed_at.is_(None),
            DeviceLinkChallenge.expires_at > now,
        )
    )
    for row in existing.scalars():
        row.consumed_at = now

    raw = generate_refresh_token()
    expires = now + timedelta(seconds=settings.device_link_expire_seconds)
    challenge = DeviceLinkChallenge(
        user_id=user.id,
        token_hash=hash_token(raw),
        expires_at=expires,
    )
    db.add(challenge)
    await db.flush()
    qr = f"{origin.rstrip('/')}/link?k={raw}"
    return DeviceLinkCreateResponse(
        id=challenge.id,
        qr=qr,
        expires_in=settings.device_link_expire_seconds,
        expires_at=expires,
    )


async def device_link_status(
    db: AsyncSession, *, user: User, link_id: UUID
) -> DeviceLinkStatusResponse:
    challenge = await db.get(DeviceLinkChallenge, link_id)
    if challenge is None or challenge.user_id != user.id:
        raise HTTPException(status_code=404, detail="Link not found")
    now = datetime.now(timezone.utc)
    if challenge.consumed_at is not None:
        status_s = "claimed"
    elif _aware(challenge.expires_at) < now:
        status_s = "expired"
    else:
        status_s = "pending"
    return DeviceLinkStatusResponse(
        id=challenge.id,
        status=status_s,
        device_name=challenge.claimed_device_name,
        expires_at=_aware(challenge.expires_at),
    )


async def revoke_device_links(db: AsyncSession, *, user: User) -> None:
    now = datetime.now(timezone.utc)
    result = await db.execute(
        select(DeviceLinkChallenge).where(
            DeviceLinkChallenge.user_id == user.id,
            DeviceLinkChallenge.consumed_at.is_(None),
        )
    )
    for row in result.scalars():
        row.consumed_at = now


async def claim_device_link(
    db: AsyncSession,
    *,
    token: str,
    device_name: str | None,
    device_id: str | None,
    ip_address: str | None,
) -> TokenResponse:
    raw = extract_device_link_token(token)
    token_hash = hash_token(raw)
    result = await db.execute(
        select(DeviceLinkChallenge).where(DeviceLinkChallenge.token_hash == token_hash)
    )
    challenge = result.scalar_one_or_none()
    now = datetime.now(timezone.utc)
    if (
        challenge is None
        or challenge.consumed_at is not None
        or _aware(challenge.expires_at) < now
    ):
        raise HTTPException(status_code=400, detail="This code is invalid or expired")

    challenge.consumed_at = now
    challenge.claimed_device_name = (device_name or "New device")[:255]
    user_result = await db.execute(
        select(User).options(selectinload(User.profile)).where(User.id == challenge.user_id)
    )
    user = user_result.scalar_one_or_none()
    if user is None or user.status != "ACTIVE":
        raise HTTPException(status_code=400, detail="This code is invalid or expired")
    return await issue_session(
        db,
        user,
        device_name=device_name,
        device_id=device_id,
        ip_address=ip_address,
        is_new_user=False,
    )
