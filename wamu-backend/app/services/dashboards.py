"""Role dashboards — customer / business / rider / admin gap endpoints."""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from decimal import Decimal

from fastapi import HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.audit import AuditLog
from app.models.business import Business, BusinessMember, MemberRole
from app.models.notification import Notification
from app.models.order import Order, OrderStatus
from app.models.order_dispute import DisputeStatus, OrderDispute
from app.models.payment import Payment, PaymentStatus
from app.models.payout import MerchantPayout, PayoutStatus
from app.models.product import Product
from app.models.report import Report
from app.models.review import Review
from app.models.rider import Delivery, DeliveryStatus, RiderProfile, RiderStatus
from app.models.user import User, UserProfile
from app.models.video import BusinessFollow
from app.services import riders as riders_service


async def customer_payments(db: AsyncSession, user: User) -> list[dict]:
    rows = (
        await db.scalars(
            select(Payment)
            .where(Payment.user_id == user.id)
            .order_by(Payment.created_at.desc())
            .limit(50)
        )
    ).all()
    return [
        {
            "id": str(p.id),
            "order_id": str(p.order_id),
            "amount": float(p.amount),
            "currency": p.currency,
            "provider": p.provider,
            "status": p.status,
            "phone": p.phone,
            "created_at": p.created_at.isoformat() if p.created_at else None,
        }
        for p in rows
    ]


async def customer_reviews(db: AsyncSession, user: User) -> list[dict]:
    rows = (
        await db.scalars(
            select(Review)
            .where(Review.user_id == user.id)
            .order_by(Review.created_at.desc())
            .limit(50)
        )
    ).all()
    out = []
    for r in rows:
        biz = await db.get(Business, r.business_id)
        out.append(
            {
                "id": str(r.id),
                "business_id": str(r.business_id),
                "business_name": biz.name if biz else "Shop",
                "rating": r.rating,
                "comment": r.comment,
                "reply": r.reply,
                "rider_rating": r.rider_rating,
                "created_at": r.created_at.isoformat() if r.created_at else None,
            }
        )
    return out


async def customer_delivery_history(db: AsyncSession, user: User) -> list[dict]:
    order_ids = (
        await db.scalars(select(Order.id).where(Order.customer_id == user.id))
    ).all()
    if not order_ids:
        return []
    rows = (
        await db.scalars(
            select(Delivery)
            .where(Delivery.order_id.in_(order_ids))
            .order_by(Delivery.created_at.desc())
            .limit(50)
        )
    ).all()
    out = []
    for d in rows:
        rider = await db.get(RiderProfile, d.rider_id) if d.rider_id else None
        out.append(
            {
                "id": str(d.id),
                "order_id": str(d.order_id),
                "status": d.status,
                "pickup_address": d.pickup_address,
                "dropoff_address": d.dropoff_address,
                "fee": float(d.fee or 0),
                "currency": d.currency or "UGX",
                "rider_name": rider.display_name if rider else None,
                "created_at": d.created_at.isoformat() if d.created_at else None,
            }
        )
    return out


async def customer_following(db: AsyncSession, user: User) -> list[dict]:
    follows = (
        await db.scalars(
            select(BusinessFollow).where(BusinessFollow.user_id == user.id)
        )
    ).all()
    out = []
    for f in follows:
        biz = await db.get(Business, f.business_id)
        if not biz or biz.deleted_at:
            continue
        out.append(
            {
                "business_id": str(biz.id),
                "name": biz.name,
                "logo_url": biz.logo_url,
                "rating": float(biz.rating or 0),
                "verification_status": biz.verification_status,
            }
        )
    return out


async def _owned_business(db: AsyncSession, user: User) -> Business:
    member = await db.scalar(
        select(BusinessMember).where(
            BusinessMember.user_id == user.id,
            BusinessMember.role.in_(
                [MemberRole.OWNER.value, MemberRole.MANAGER.value, "OWNER", "MANAGER"]
            ),
        )
    )
    if member:
        biz = await db.get(Business, member.business_id)
        if biz and not biz.deleted_at:
            return biz
    biz = await db.scalar(
        select(Business).where(Business.owner_id == user.id, Business.deleted_at.is_(None))
    )
    if not biz:
        raise HTTPException(status_code=404, detail="No business found for this account")
    return biz


async def business_overview(db: AsyncSession, user: User) -> dict:
    biz = await _owned_business(db, user)
    orders = (
        await db.scalars(select(Order).where(Order.business_id == biz.id))
    ).all()
    by_status: dict[str, int] = {}
    gmv = Decimal("0")
    for o in orders:
        by_status[o.status] = by_status.get(o.status, 0) + 1
        if o.status not in {OrderStatus.CANCELLED.value, OrderStatus.PENDING.value}:
            gmv += Decimal(str(o.total or 0))
    paid = await db.scalar(
        select(func.coalesce(func.sum(Payment.amount), 0))
        .join(Order, Order.id == Payment.order_id)
        .where(Order.business_id == biz.id, Payment.status == PaymentStatus.SUCCESS.value)
    )
    product_count = await db.scalar(
        select(func.count()).select_from(Product).where(Product.business_id == biz.id)
    ) or 0
    review_count = await db.scalar(
        select(func.count()).select_from(Review).where(Review.business_id == biz.id)
    ) or 0
    earnings = await db.scalar(
        select(func.coalesce(func.sum(MerchantPayout.amount), 0)).where(
            MerchantPayout.business_id == biz.id,
            MerchantPayout.status == PayoutStatus.SUCCESS.value,
        )
    )
    return {
        "business_id": str(biz.id),
        "name": biz.name,
        "verification_status": biz.verification_status,
        "orders_total": len(orders),
        "orders_by_status": by_status,
        "gmv_ugx": float(gmv),
        "paid_ugx": float(paid or 0),
        "earnings_ugx": float(earnings or 0),
        "product_count": int(product_count),
        "review_count": int(review_count),
        "rating": float(biz.rating or 0),
        "promo_text": (biz.description or "").split("\nPROMO:", 1)[-1].strip()
        if biz.description and "\nPROMO:" in biz.description
        else None,
    }


async def business_customers(db: AsyncSession, user: User) -> list[dict]:
    biz = await _owned_business(db, user)
    rows = await db.execute(
        select(
            Order.customer_id,
            func.count(Order.id),
            func.coalesce(func.sum(Order.total), 0),
            func.max(Order.created_at),
        )
        .where(Order.business_id == biz.id)
        .group_by(Order.customer_id)
        .order_by(func.count(Order.id).desc())
        .limit(100)
    )
    out = []
    for customer_id, order_count, spent, last_at in rows.all():
        u = await db.get(User, customer_id)
        prof = await db.scalar(select(UserProfile).where(UserProfile.user_id == customer_id))
        name = " ".join(
            p for p in [(prof.first_name if prof else None), (prof.last_name if prof else None)] if p
        ).strip()
        out.append(
            {
                "user_id": str(customer_id),
                "phone": u.phone if u else None,
                "name": name or (u.phone if u else "Customer"),
                "orders": int(order_count),
                "spent_ugx": float(spent or 0),
                "last_order_at": last_at.isoformat() if last_at else None,
            }
        )
    return out


async def business_staff(db: AsyncSession, user: User) -> list[dict]:
    biz = await _owned_business(db, user)
    members = (
        await db.scalars(
            select(BusinessMember).where(BusinessMember.business_id == biz.id)
        )
    ).all()
    out = []
    for m in members:
        u = await db.get(User, m.user_id)
        prof = await db.scalar(select(UserProfile).where(UserProfile.user_id == m.user_id))
        name = " ".join(
            p for p in [(prof.first_name if prof else None), (prof.last_name if prof else None)] if p
        ).strip()
        out.append(
            {
                "user_id": str(m.user_id),
                "phone": u.phone if u else None,
                "name": name or (u.phone if u else "Staff"),
                "role": m.role,
            }
        )
    return out


async def add_business_staff(
    db: AsyncSession, user: User, phone: str, role: str = "STAFF"
) -> dict:
    biz = await _owned_business(db, user)
    if not await _is_owner(db, user, biz):
        raise HTTPException(status_code=403, detail="Only owners can add staff")
    phone = phone.strip()
    staff = await db.scalar(select(User).where(User.phone == phone))
    if not staff:
        raise HTTPException(status_code=404, detail="User not found — they must login once first")
    existing = await db.scalar(
        select(BusinessMember).where(
            BusinessMember.business_id == biz.id, BusinessMember.user_id == staff.id
        )
    )
    if existing:
        existing.role = role.upper()
    else:
        db.add(
            BusinessMember(
                business_id=biz.id,
                user_id=staff.id,
                role=role.upper() if role.upper() in {"STAFF", "MANAGER", "OWNER"} else "STAFF",
            )
        )
    await db.flush()
    return {"ok": True, "user_id": str(staff.id), "phone": phone, "role": role.upper()}


async def _is_owner(db: AsyncSession, user: User, biz: Business) -> bool:
    if biz.owner_id == user.id:
        return True
    m = await db.scalar(
        select(BusinessMember).where(
            BusinessMember.business_id == biz.id,
            BusinessMember.user_id == user.id,
            BusinessMember.role.in_([MemberRole.OWNER.value, "OWNER"]),
        )
    )
    return m is not None


async def update_business_settings(
    db: AsyncSession, user: User, *, name: str | None, phone: str | None, description: str | None, promo_text: str | None
) -> dict:
    biz = await _owned_business(db, user)
    if not await _is_owner(db, user, biz):
        raise HTTPException(status_code=403, detail="Only owners can edit settings")
    if name is not None and name.strip():
        biz.name = name.strip()
    if phone is not None:
        biz.phone = phone.strip() or None
    # Store promo in description as PROMO: suffix to avoid migration.
    base_desc = description if description is not None else (biz.description or "")
    if description is not None:
        base_desc = description
    if "\nPROMO:" in (base_desc or ""):
        base_desc = (base_desc or "").split("\nPROMO:", 1)[0]
    if promo_text is not None:
        promo = promo_text.strip()
        biz.description = f"{base_desc.rstrip()}\nPROMO:{promo}" if promo else base_desc
    elif description is not None:
        biz.description = base_desc
    await db.flush()
    return {
        "id": str(biz.id),
        "name": biz.name,
        "phone": biz.phone,
        "description": biz.description,
        "promo_text": (biz.description or "").split("\nPROMO:", 1)[-1].strip()
        if biz.description and "\nPROMO:" in biz.description
        else None,
    }


async def set_rider_availability(
    db: AsyncSession,
    user: User,
    *,
    available_delivery: bool | None = None,
    available_rides: bool | None = None,
) -> dict:
    rider = await riders_service.get_my_rider_profile(db, user)
    if not rider:
        raise HTTPException(status_code=404, detail="Not enrolled as a rider")
    if rider.status != RiderStatus.APPROVED.value:
        raise HTTPException(
            status_code=400,
            detail=f"Cannot go online while status is {rider.status} — complete verification first",
        )
    if available_delivery is not None:
        rider.available_delivery = available_delivery
    if available_rides is not None:
        rider.available_rides = available_rides
    await db.flush()
    return {
        "id": str(rider.id),
        "status": rider.status,
        "available_delivery": rider.available_delivery,
        "available_rides": rider.available_rides,
    }


async def rider_earnings(db: AsyncSession, user: User) -> dict:
    rider = await riders_service.get_my_rider_profile(db, user)
    if not rider:
        raise HTTPException(status_code=404, detail="Not enrolled as a rider")
    delivered = (
        await db.scalars(
            select(Delivery).where(
                Delivery.rider_id == rider.id,
                Delivery.status == DeliveryStatus.DELIVERED.value,
            )
        )
    ).all()
    total = sum((Decimal(str(d.fee or 0)) for d in delivered), Decimal("0"))
    return {
        "rider_id": str(rider.id),
        "display_name": rider.display_name,
        "rating": float(rider.rating or 0),
        "delivery_count": rider.delivery_count,
        "completed_deliveries": len(delivered),
        "earnings_ugx": float(total),
        "available_delivery": rider.available_delivery,
        "available_rides": rider.available_rides,
        "vehicle_type": rider.vehicle_type,
        "plate_number": rider.plate_number,
        "status": rider.status,
    }


async def update_rider_vehicle(
    db: AsyncSession, user: User, *, vehicle_type: str | None, plate_number: str | None, display_name: str | None
) -> dict:
    rider = await riders_service.get_my_rider_profile(db, user)
    if not rider:
        raise HTTPException(status_code=404, detail="Not enrolled as a rider")
    if vehicle_type:
        rider.vehicle_type = vehicle_type.strip().upper()
    if plate_number is not None:
        rider.plate_number = plate_number.strip() or None
    if display_name and display_name.strip():
        rider.display_name = display_name.strip()
    await db.flush()
    return riders_service._rider_resp(rider).model_dump(mode="json")


async def admin_list_riders(db: AsyncSession, status: str | None = None) -> list[dict]:
    q = select(RiderProfile).where(RiderProfile.deleted_at.is_(None))
    if status:
        st = status.upper()
        # Admin UI "PENDING" = awaiting verification / decision
        if st == "PENDING":
            q = q.where(
                RiderProfile.status.in_(
                    [
                        RiderStatus.DRAFT.value,
                        RiderStatus.SUBMITTED.value,
                        RiderStatus.UNDER_REVIEW.value,
                        RiderStatus.NEEDS_REUPLOAD.value,
                    ]
                )
            )
        else:
            q = q.where(RiderProfile.status == st)
    rows = (
        await db.scalars(q.order_by(RiderProfile.created_at.desc()).limit(200))
    ).all()
    out = []
    for r in rows:
        u = await db.get(User, r.user_id)
        delivered = (
            await db.scalar(
                select(func.count())
                .select_from(Delivery)
                .where(
                    Delivery.rider_id == r.id,
                    Delivery.status == DeliveryStatus.DELIVERED.value,
                )
            )
            or 0
        )
        out.append(
            {
                "id": str(r.id),
                "user_id": str(r.user_id),
                "phone": u.phone if u else None,
                "display_name": r.display_name,
                "wamu_rider_ref": r.wamu_rider_ref,
                "vehicle_type": r.vehicle_type,
                "plate_number": r.plate_number,
                "status": r.status,
                "ai_result": r.ai_result,
                "submitted_at": r.submitted_at.isoformat() if r.submitted_at else None,
                "available_delivery": r.available_delivery,
                "available_rides": r.available_rides,
                "rating": float(r.rating or 0),
                "delivery_count": r.delivery_count,
                "ride_count": r.ride_count,
                "completed_deliveries": int(delivered),
                "lat": float(r.lat) if r.lat is not None else None,
                "lng": float(r.lng) if r.lng is not None else None,
                "created_at": r.created_at.isoformat() if r.created_at else None,
            }
        )
    return out


async def admin_rider_detail(db: AsyncSession, rider_id: uuid.UUID) -> dict:
    rider = await db.get(RiderProfile, rider_id)
    if not rider or rider.deleted_at:
        raise HTTPException(status_code=404, detail="Rider not found")
    base = (await admin_list_riders(db))
    row = next((x for x in base if x["id"] == str(rider_id)), None)
    if not row:
        rows = await admin_list_riders(db)
        row = next((x for x in rows if x["id"] == str(rider_id)), None)
    deliveries = (
        await db.scalars(
            select(Delivery)
            .where(Delivery.rider_id == rider.id)
            .order_by(Delivery.created_at.desc())
            .limit(50)
        )
    ).all()
    fee_total = sum(
        (Decimal(str(d.fee or 0)) for d in deliveries if d.status == DeliveryStatus.DELIVERED.value),
        Decimal("0"),
    )
    from app.services import rider_verification as rv

    verification = await rv.admin_verification_detail(db, rider_id)
    return {
        **(row or {"id": str(rider.id)}),
        "earnings_ugx": float(fee_total),
        "verification": verification,
        "recent_deliveries": [
            {
                "id": str(d.id),
                "order_id": str(d.order_id),
                "status": d.status,
                "fee": float(d.fee or 0),
                "dropoff_address": d.dropoff_address,
                "created_at": d.created_at.isoformat() if d.created_at else None,
            }
            for d in deliveries
        ],
    }


async def admin_set_rider_status(
    db: AsyncSession,
    admin: User,
    rider_id: uuid.UUID,
    *,
    action: str,
    note: str | None = None,
    reupload_fields: list[str] | None = None,
) -> dict:
    """Delegate to rider verification moderation (approve / reject / reupload / suspend)."""
    from app.services import rider_verification as rv

    return await rv.admin_moderation_action(
        db,
        admin,
        rider_id,
        action=action,
        note=note,
        reupload_fields=reupload_fields,
    )


async def admin_list_deliveries(db: AsyncSession) -> list[dict]:
    rows = (
        await db.scalars(select(Delivery).order_by(Delivery.created_at.desc()).limit(200))
    ).all()
    out = []
    for d in rows:
        rider = await db.get(RiderProfile, d.rider_id) if d.rider_id else None
        out.append(
            {
                "id": str(d.id),
                "order_id": str(d.order_id),
                "status": d.status,
                "pickup_address": d.pickup_address,
                "dropoff_address": d.dropoff_address,
                "fee": float(d.fee or 0),
                "rider_name": rider.display_name if rider else None,
                "rider_id": str(d.rider_id) if d.rider_id else None,
                "created_at": d.created_at.isoformat() if d.created_at else None,
            }
        )
    return out


async def admin_audit_logs(db: AsyncSession, limit: int = 100) -> list[dict]:
    rows = (
        await db.scalars(
            select(AuditLog).order_by(AuditLog.created_at.desc()).limit(min(limit, 500))
        )
    ).all()
    return [
        {
            "id": str(a.id),
            "actor_id": str(a.actor_id) if a.actor_id else None,
            "action": a.action,
            "entity_type": a.entity_type,
            "entity_id": str(a.entity_id) if a.entity_id else None,
            "metadata": a.metadata_json,
            "created_at": a.created_at.isoformat() if a.created_at else None,
        }
        for a in rows
    ]


async def admin_fraud_signals(db: AsyncSession) -> dict:
    suspended = (
        await db.scalar(select(func.count()).select_from(User).where(User.status == "SUSPENDED"))
        or 0
    )
    failed_pay = (
        await db.scalar(
            select(func.count())
            .select_from(Payment)
            .where(Payment.status == PaymentStatus.FAILED.value)
        )
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
    open_reports = (
        await db.scalar(select(func.count()).select_from(Report).where(Report.status == "OPEN"))
        or 0
    )
    manual_refunds = (
        await db.scalar(
            select(func.count())
            .select_from(AuditLog)
            .where(AuditLog.action == "PAYMENT_MANUAL_REFUND_REQUIRED")
        )
        or 0
    )
    signals = []
    if suspended:
        signals.append({"level": "warn", "code": "SUSPENDED_USERS", "count": suspended})
    if failed_pay >= 5:
        signals.append({"level": "warn", "code": "FAILED_PAYMENTS", "count": failed_pay})
    if open_disputes:
        signals.append({"level": "info", "code": "OPEN_DISPUTES", "count": open_disputes})
    if open_reports:
        signals.append({"level": "info", "code": "OPEN_REPORTS", "count": open_reports})
    if manual_refunds:
        signals.append({"level": "warn", "code": "MANUAL_REFUNDS", "count": manual_refunds})
    return {
        "status": "ok" if not any(s["level"] == "warn" for s in signals) else "attention",
        "signals": signals,
        "checked_at": datetime.now(timezone.utc).isoformat(),
    }


async def admin_recent_notifications(db: AsyncSession, limit: int = 50) -> list[dict]:
    rows = (
        await db.scalars(
            select(Notification).order_by(Notification.created_at.desc()).limit(min(limit, 200))
        )
    ).all()
    return [
        {
            "id": str(n.id),
            "user_id": str(n.user_id),
            "type": n.type,
            "title": n.title,
            "body": n.body,
            "created_at": n.created_at.isoformat() if n.created_at else None,
        }
        for n in rows
    ]


async def admin_broadcast(
    db: AsyncSession, admin: User, *, title: str, body: str, audience: str = "ALL"
) -> dict:
    q = select(User)
    if audience.upper() == "RIDERS":
        rider_ids = await db.scalars(select(RiderProfile.user_id))
        ids = list(rider_ids.all())
        if not ids:
            return {"sent": 0}
        q = q.where(User.id.in_(ids))
    elif audience.upper() == "BUSINESSES":
        owner_ids = await db.scalars(select(Business.owner_id).where(Business.deleted_at.is_(None)))
        ids = list(owner_ids.all())
        if not ids:
            return {"sent": 0}
        q = q.where(User.id.in_(ids))
    users = (await db.scalars(q.limit(500))).all()
    for u in users:
        db.add(
            Notification(
                user_id=u.id,
                type="ADMIN_BROADCAST",
                title=title[:120],
                body=body[:500],
                data={"audience": audience, "from_admin": str(admin.id)},
            )
        )
    db.add(
        AuditLog(
            actor_id=admin.id,
            action="ADMIN_BROADCAST",
            entity_type="notification",
            entity_id=None,
            metadata_json={"title": title, "audience": audience, "count": len(users)},
        )
    )
    await db.flush()
    return {"sent": len(users), "audience": audience}
