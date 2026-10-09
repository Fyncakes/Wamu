"""Business and category domain services."""

from __future__ import annotations

import uuid
from decimal import Decimal

from fastapi import HTTPException
from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.audit import AuditLog
from app.models.business import (
    Business,
    BusinessMember,
    Location,
    MemberRole,
    VerificationStatus,
)
from app.models.notification import Notification
from app.models.user import User, UserProfile, UserRole
from app.schemas.marketplace import BusinessCreate, BusinessUpdate
from app.services.utils import slugify


async def create_business(db: AsyncSession, user: User, data: BusinessCreate) -> Business:
    base_slug = slugify(data.name)
    slug = base_slug
    i = 1
    while True:
        exists = await db.scalar(select(Business.id).where(Business.slug == slug))
        if not exists:
            break
        i += 1
        slug = f"{base_slug}-{i}"

    # Default shop media so VERIFIED merchants appear in the public catalog
    # even before they upload a custom logo (customer list requires logo/cover).
    name_l = (data.name or "").lower()
    if any(k in name_l for k in ("cake", "bakery", "pastry", "dessert")):
        default_logo = "/media-files/seed/shops/bakery_logo.jpg"
        default_cover = "/media-files/seed/shops/bakery_cover.jpg"
    else:
        default_logo = "/media-files/seed/shops/food_logo.jpg"
        default_cover = "/media-files/seed/shops/food_cover.jpg"
    business = Business(
        owner_id=user.id,
        name=data.name,
        slug=slug,
        description=data.description,
        phone=data.phone or user.phone,
        payout_phone=data.payout_phone,
        payout_provider=data.payout_provider,
        email=data.email,
        category_id=data.category_id,
        verification_status=VerificationStatus.PENDING.value,
        logo_url=default_logo,
        cover_url=default_cover,
    )
    db.add(business)
    await db.flush()
    db.add(
        BusinessMember(
            business_id=business.id,
            user_id=user.id,
            role=MemberRole.OWNER.value,
        )
    )
    if data.location:
        loc = data.location
        # Kampala beachhead default so nearby Discover can find the shop.
        lat = loc.latitude if loc.latitude is not None else Decimal("0.3476000")
        lng = loc.longitude if loc.longitude is not None else Decimal("32.5825000")
        db.add(
            Location(
                business_id=business.id,
                address_line=loc.address_line,
                city=loc.city or "Kampala",
                district=loc.district,
                latitude=lat,
                longitude=lng,
            )
        )
    if user.role == UserRole.CUSTOMER.value:
        user.role = UserRole.BUSINESS.value
    # Capability flag so Flutter "My business" unlocks without a separate toggle.
    if user.profile is not None:
        user.profile.owns_business = True
    else:
        db.add(
            UserProfile(
                user_id=user.id,
                first_name="Merchant",
                owns_business=True,
            )
        )
    db.add(
        AuditLog(
            actor_id=user.id,
            action="BUSINESS_CREATED",
            entity_type="business",
            entity_id=business.id,
        )
    )
    await db.flush()
    result = await db.execute(
        select(Business)
        .options(selectinload(Business.location))
        .where(Business.id == business.id)
    )
    from app.core.metrics import BUSINESS_CREATED, metrics

    metrics.incr(BUSINESS_CREATED)
    return result.scalar_one()


async def list_owned_businesses(db: AsyncSession, user: User) -> list[Business]:
    result = await db.execute(
        select(Business)
        .options(selectinload(Business.location))
        .where(Business.owner_id == user.id, Business.deleted_at.is_(None))
        .order_by(Business.created_at.desc())
    )
    return list(result.scalars().all())


async def get_business(db: AsyncSession, business_id: uuid.UUID) -> Business:
    result = await db.execute(
        select(Business)
        .options(selectinload(Business.location), selectinload(Business.products))
        .where(Business.id == business_id, Business.deleted_at.is_(None))
    )
    business = result.scalar_one_or_none()
    if not business:
        raise HTTPException(status_code=404, detail="Business not found")
    return business


def _haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    from math import asin, cos, radians, sin, sqrt

    dlat = radians(lat2 - lat1)
    dlon = radians(lon2 - lon1)
    a = sin(dlat / 2) ** 2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(dlon / 2) ** 2
    return 6371.0 * 2 * asin(sqrt(a))


async def list_businesses(
    db: AsyncSession,
    *,
    category_id: uuid.UUID | None = None,
    q: str | None = None,
    page: int = 1,
    page_size: int = 20,
    lat: float | None = None,
    lng: float | None = None,
    radius_km: float | None = None,
) -> tuple[list[Business], int]:
    page_size = min(max(page_size, 1), 100)
    media_ok = or_(
        (Business.logo_url.is_not(None) & (Business.logo_url != "")),
        (Business.cover_url.is_not(None) & (Business.cover_url != "")),
    )
    stmt = select(Business).options(selectinload(Business.location)).where(
        Business.deleted_at.is_(None),
        Business.status == "ACTIVE",
        media_ok,
    )
    if category_id:
        stmt = stmt.where(Business.category_id == category_id)
    if q:
        like = f"%{q}%"
        stmt = stmt.where(Business.name.ilike(like) | Business.description.ilike(like))

    # Nearby filter: fetch a wider window then distance-sort (MVP scale).
    nearby = lat is not None and lng is not None
    fetch_limit = 500 if nearby else page_size
    fetch_offset = 0 if nearby else (page - 1) * page_size
    stmt = stmt.order_by(Business.verification_status.desc(), Business.rating.desc())
    if not nearby:
        count_stmt = select(func.count()).select_from(Business).where(
            Business.deleted_at.is_(None),
            Business.status == "ACTIVE",
            media_ok,
        )
        if category_id:
            count_stmt = count_stmt.where(Business.category_id == category_id)
        if q:
            like = f"%{q}%"
            count_stmt = count_stmt.where(
                Business.name.ilike(like) | Business.description.ilike(like)
            )
        total = await db.scalar(count_stmt) or 0
        stmt = stmt.offset(fetch_offset).limit(fetch_limit)
        rows = list((await db.execute(stmt)).scalars().all())
        return rows, int(total)

    rows = list((await db.execute(stmt.limit(fetch_limit))).scalars().all())
    radius = radius_km if radius_km is not None else 15.0
    scored: list[tuple[float, Business]] = []
    for biz in rows:
        loc = biz.location
        if not loc or loc.latitude is None or loc.longitude is None:
            continue
        dist = _haversine_km(lat, lng, float(loc.latitude), float(loc.longitude))
        if dist <= radius:
            scored.append((dist, biz))
    scored.sort(key=lambda t: (t[0], -(float(t[1].rating or 0))))
    total = len(scored)
    start = (page - 1) * page_size
    page_rows = [b for _, b in scored[start : start + page_size]]
    return page_rows, total


async def assert_business_member(
    db: AsyncSession, user: User, business_id: uuid.UUID, roles: set[str] | None = None
) -> BusinessMember:
    result = await db.execute(
        select(BusinessMember).where(
            BusinessMember.business_id == business_id,
            BusinessMember.user_id == user.id,
            BusinessMember.is_active.is_(True),
        )
    )
    member = result.scalar_one_or_none()
    if not member and user.role != UserRole.ADMIN.value:
        raise HTTPException(status_code=403, detail="Not a business member")
    if roles and member and member.role not in roles and user.role != UserRole.ADMIN.value:
        raise HTTPException(status_code=403, detail="Insufficient business role")
    return member  # type: ignore[return-value]


async def update_business(
    db: AsyncSession, user: User, business_id: uuid.UUID, data: BusinessUpdate
) -> Business:
    await assert_business_member(
        db, user, business_id, {MemberRole.OWNER.value, MemberRole.MANAGER.value}
    )
    business = await get_business(db, business_id)
    for field, value in data.model_dump(exclude_unset=True, exclude={"location"}).items():
        setattr(business, field, value)
    if data.location:
        if business.location:
            for f, v in data.location.model_dump(exclude_unset=True).items():
                setattr(business.location, f, v)
        else:
            db.add(
                Location(
                    business_id=business.id,
                    **data.location.model_dump(),
                )
            )
    business.version += 1
    await db.flush()
    return await get_business(db, business_id)


async def set_verification(
    db: AsyncSession, admin: User, business_id: uuid.UUID, status: str
) -> Business:
    business = await get_business(db, business_id)
    business.verification_status = status
    db.add(
        AuditLog(
            actor_id=admin.id,
            action="BUSINESS_VERIFICATION",
            entity_type="business",
            entity_id=business.id,
            metadata_json={"status": status},
        )
    )
    if status == VerificationStatus.VERIFIED.value:
        db.add(
            Notification(
                user_id=business.owner_id,
                type="BUSINESS_VERIFIED",
                title="Business verified",
                body=f"{business.name} is verified on Wamu — customers will see the badge.",
                data={
                    "business_id": str(business.id),
                    "audience": "merchant",
                },
            )
        )
    await db.flush()
    return business
