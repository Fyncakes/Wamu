"""Reviews, favorites, reports, notifications, AI Level-1 search."""

from __future__ import annotations

import re
import uuid
from decimal import Decimal

from fastapi import HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.business import Business, MemberRole
from app.models.favorite import Favorite
from app.models.notification import Notification
from app.models.order import Order, OrderStatus
from app.models.report import Report
from app.models.review import Review
from app.models.user import User
from app.schemas.commerce import AISearchRequest, ReportCreate, ReportResolve, ReviewCreate, ReviewReply
from app.schemas.marketplace import BusinessResponse, ProductResponse
from app.services.business import assert_business_member, get_business
from app.services.product import search as marketplace_search


async def create_review(db: AsyncSession, user: User, data: ReviewCreate) -> Review:
    existing = await db.scalar(
        select(Review).where(Review.business_id == data.business_id, Review.user_id == user.id)
    )
    if existing:
        raise HTTPException(status_code=400, detail="You already reviewed this business")
    await get_business(db, data.business_id)

    order = await db.get(Order, data.order_id)
    if not order:
        raise HTTPException(status_code=404, detail="Order not found")
    if order.customer_id != user.id:
        raise HTTPException(status_code=403, detail="Not your order")
    if order.business_id != data.business_id:
        raise HTTPException(status_code=400, detail="Order does not belong to this business")
    if order.status != OrderStatus.DELIVERED.value:
        raise HTTPException(
            status_code=400,
            detail="Only delivered orders can be reviewed",
        )

    rider_id = None
    if data.rider_rating is not None:
        from app.models.rider import Delivery

        delivery = await db.scalar(select(Delivery).where(Delivery.order_id == order.id))
        if not delivery or not delivery.rider_id:
            raise HTTPException(status_code=400, detail="No rider to rate for this order")
        rider_id = delivery.rider_id

    review = Review(
        business_id=data.business_id,
        user_id=user.id,
        order_id=data.order_id,
        rating=data.rating,
        comment=data.comment,
        rider_id=rider_id,
        rider_rating=data.rider_rating if rider_id else None,
    )
    db.add(review)
    await db.flush()
    await _recompute_business_rating(db, data.business_id)
    if rider_id and data.rider_rating is not None:
        await _recompute_rider_rating(db, rider_id)
    from app.core.metrics import REVIEW_CREATED, metrics

    metrics.incr(REVIEW_CREATED)
    await db.refresh(review)
    return review


async def _recompute_business_rating(db: AsyncSession, business_id: uuid.UUID) -> None:
    avg, count = (
        await db.execute(
            select(func.avg(Review.rating), func.count(Review.id)).where(
                Review.business_id == business_id
            )
        )
    ).one()
    business = await db.get(Business, business_id)
    if business:
        business.rating = Decimal(str(round(float(avg or 0), 2)))
        business.review_count = int(count or 0)
        await db.flush()


async def _recompute_rider_rating(db: AsyncSession, rider_id: uuid.UUID) -> None:
    from app.models.rider import RiderProfile

    avg, count = (
        await db.execute(
            select(func.avg(Review.rider_rating), func.count(Review.id)).where(
                Review.rider_id == rider_id,
                Review.rider_rating.is_not(None),
            )
        )
    ).one()
    rider = await db.get(RiderProfile, rider_id)
    if rider and count:
        rider.rating = Decimal(str(round(float(avg or 5), 2)))
        await db.flush()


async def reply_review(
    db: AsyncSession, user: User, review_id: uuid.UUID, data: ReviewReply
) -> Review:
    review = await db.get(Review, review_id)
    if not review:
        raise HTTPException(status_code=404, detail="Review not found")
    await assert_business_member(
        db, user, review.business_id, {MemberRole.OWNER.value, MemberRole.MANAGER.value}
    )
    review.reply = data.reply
    await db.flush()
    db.add(
        Notification(
            user_id=review.user_id,
            type="REVIEW_REPLY",
            title="Business replied to your review",
            body=data.reply[:200],
            data={"review_id": str(review.id), "business_id": str(review.business_id)},
        )
    )
    await db.flush()
    return review


async def list_reviews(db: AsyncSession, business_id: uuid.UUID) -> list[Review]:
    result = await db.execute(
        select(Review).where(Review.business_id == business_id).order_by(Review.created_at.desc())
    )
    return list(result.scalars().all())


async def add_favorite(db: AsyncSession, user: User, business_id: uuid.UUID) -> Favorite:
    await get_business(db, business_id)
    existing = await db.scalar(
        select(Favorite).where(Favorite.user_id == user.id, Favorite.business_id == business_id)
    )
    if existing:
        return existing
    fav = Favorite(user_id=user.id, business_id=business_id)
    db.add(fav)
    await db.flush()
    return fav


async def remove_favorite(db: AsyncSession, user: User, business_id: uuid.UUID) -> None:
    fav = await db.scalar(
        select(Favorite).where(Favorite.user_id == user.id, Favorite.business_id == business_id)
    )
    if fav:
        await db.delete(fav)
        await db.flush()


async def list_favorites(db: AsyncSession, user: User) -> list[Business]:
    result = await db.execute(
        select(Business)
        .join(Favorite, Favorite.business_id == Business.id)
        .options(selectinload(Business.location))
        .where(Favorite.user_id == user.id)
    )
    return list(result.scalars().all())


async def create_report(db: AsyncSession, user: User, data: ReportCreate) -> Report:
    report = Report(
        reporter_id=user.id,
        target_type=data.target_type,
        target_id=data.target_id,
        reason=data.reason,
        description=data.description,
    )
    db.add(report)
    await db.flush()
    await db.refresh(report)
    return report


async def resolve_report(
    db: AsyncSession, admin: User, report_id: uuid.UUID, data: ReportResolve
) -> Report:
    report = await db.get(Report, report_id)
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")
    report.status = data.status
    report.resolution_note = data.resolution_note
    await db.flush()
    return report


async def list_notifications(db: AsyncSession, user: User) -> list[Notification]:
    result = await db.execute(
        select(Notification)
        .where(Notification.user_id == user.id)
        .order_by(Notification.created_at.desc())
        .limit(100)
    )
    return list(result.scalars().all())


async def mark_notification_read(
    db: AsyncSession, user: User, notification_id: uuid.UUID
) -> Notification:
    n = await db.get(Notification, notification_id)
    if not n or n.user_id != user.id:
        raise HTTPException(status_code=404, detail="Notification not found")
    n.is_read = True
    await db.flush()
    return n


async def ai_search(db: AsyncSession, data: AISearchRequest) -> dict:
    """
    Level-1 AI assistant: interpret natural language → structured WAMU search.

    CRITICAL: Only return businesses/products from our database.
    Never invent listings, prices, or ratings.
    """
    query = data.query.strip()
    # Lightweight intent parsing without an external LLM for MVP reliability
    location_hint = None
    m = re.search(r"\bnear(?:\s+me)?\s+([A-Za-z]+)|in\s+([A-Za-z]+)", query, re.I)
    if m:
        location_hint = (m.group(1) or m.group(2) or "").title()

    # Strip location phrases for keyword search
    keywords = re.sub(
        r"\b(near me|near|in|find|cheap|best|ugx)\b", " ", query, flags=re.I
    )
    keywords = re.sub(r"\s+", " ", keywords).strip() or query
    # Prefer primary noun tokens so "cake Ntinda" still finds cakes
    tokens = [t for t in keywords.split() if len(t) > 2]
    search_q = tokens[0] if tokens else keywords

    results = await marketplace_search(db, q=search_q, page=1, page_size=10)
    businesses = results["businesses"]
    products = results["products"]

    if location_hint:
        filtered = [
            b
            for b in businesses
            if b.location
            and (
                (b.location.city or "").lower() == location_hint.lower()
                or (b.location.district or "").lower() == location_hint.lower()
                or location_hint.lower() in (b.location.address_line or "").lower()
            )
        ]
        # Keep unfiltered catalog hits if location filter yields nothing
        if filtered:
            businesses = filtered

    interpretation_parts = [f"Searching WAMU for “{search_q}”"]
    if location_hint:
        interpretation_parts.append(f"focusing on {location_hint}")
    interpretation_parts.append(
        f"— found {len(businesses)} businesses and {len(products)} products in our catalog."
    )

    return {
        "interpretation": " ".join(interpretation_parts),
        "businesses": [
            BusinessResponse.model_validate(b).model_dump(mode="json") for b in businesses
        ],
        "products": [
            ProductResponse.model_validate(p).model_dump(mode="json") for p in products
        ],
    }
