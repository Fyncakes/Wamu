"""Self-serve deactivate / delete and admin account removal."""

from __future__ import annotations

import uuid
from datetime import datetime, timezone

from fastapi import HTTPException
from sqlalchemy import delete, select, update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.admins import is_permanent_admin_phone
from app.models.audit import AuditLog
from app.models.block import UserBlock
from app.models.business import Business
from app.models.chat import Message
from app.models.device import DevicePushToken
from app.models.favorite import Favorite
from app.models.notification import Notification
from app.models.product import Product
from app.models.rider import RiderProfile
from app.models.status import StatusUpdate
from app.models.user import DeviceLinkChallenge, OtpChallenge, Session, User, UserStatus
from app.models.video import BusinessVideo


def _tombstone_phone(user_id: uuid.UUID) -> str:
    # users.phone is String(20); keep a unique non-dialable value.
    return f"d{user_id.hex[:18]}"


async def _revoke_sessions(db: AsyncSession, user_id: uuid.UUID) -> None:
    now = datetime.now(timezone.utc)
    await db.execute(
        update(Session)
        .where(Session.user_id == user_id, Session.revoked_at.is_(None))
        .values(revoked_at=now)
    )


async def deactivate_own_account(db: AsyncSession, user: User) -> User:
    """Pause the account. Signing in with OTP turns it back on."""
    if is_permanent_admin_phone(user.phone):
        raise HTTPException(status_code=400, detail="This admin account cannot be deactivated")
    if user.status == UserStatus.DELETED.value:
        raise HTTPException(status_code=400, detail="Account already deleted")
    user.status = UserStatus.DEACTIVATED.value
    await _revoke_sessions(db, user.id)
    db.add(
        AuditLog(
            actor_id=user.id,
            action="USER_DEACTIVATE",
            entity_type="user",
            entity_id=user.id,
            metadata_json={"status": UserStatus.DEACTIVATED.value},
        )
    )
    await db.flush()
    return user


async def purge_user_account(
    db: AsyncSession,
    *,
    target: User,
    actor: User,
    reason: str,
) -> dict:
    """
    Remove personal data from Wamu while keeping payment/order rows for the ledger.
    The phone number is freed so a fresh account can be created later.
    """
    if is_permanent_admin_phone(target.phone):
        raise HTTPException(status_code=400, detail="This admin account cannot be deleted")
    if target.status == UserStatus.DELETED.value:
        raise HTTPException(status_code=400, detail="Account already deleted")

    now = datetime.now(timezone.utc)
    original_phone = target.phone
    user_id = target.id

    await _revoke_sessions(db, user_id)

    await db.execute(delete(DeviceLinkChallenge).where(DeviceLinkChallenge.user_id == user_id))
    await db.execute(delete(DevicePushToken).where(DevicePushToken.user_id == user_id))
    await db.execute(delete(Notification).where(Notification.user_id == user_id))
    await db.execute(delete(Favorite).where(Favorite.user_id == user_id))
    await db.execute(
        delete(UserBlock).where(
            (UserBlock.blocker_id == user_id) | (UserBlock.blocked_id == user_id)
        )
    )
    await db.execute(delete(StatusUpdate).where(StatusUpdate.user_id == user_id))
    await db.execute(delete(OtpChallenge).where(OtpChallenge.phone == original_phone))

    # Scrub chat content the user sent; keep rows so peer threads stay intact.
    await db.execute(
        update(Message)
        .where(Message.sender_id == user_id, Message.deleted_at.is_(None))
        .values(body="", media_url=None, deleted_at=now)
    )

    businesses = list(
        (
            await db.execute(
                select(Business).where(Business.owner_id == user_id, Business.deleted_at.is_(None))
            )
        ).scalars()
    )
    business_ids = [b.id for b in businesses]
    for biz in businesses:
        biz.deleted_at = now
        biz.status = "SUSPENDED"
        biz.phone = None
        biz.payout_phone = None
        biz.email = None
        biz.owner_full_name = None
        biz.owner_nin = None
        biz.tin = None
        biz.logo_url = None
        biz.cover_url = None
        biz.description = None
        biz.name = f"Removed shop {str(biz.id)[:8]}"
        biz.slug = f"removed-{biz.id.hex[:16]}"

    if business_ids:
        await db.execute(
            update(Product)
            .where(Product.business_id.in_(business_ids), Product.deleted_at.is_(None))
            .values(deleted_at=now, is_active=False, status="INACTIVE")
        )
        await db.execute(
            update(BusinessVideo)
            .where(BusinessVideo.business_id.in_(business_ids), BusinessVideo.deleted_at.is_(None))
            .values(
                deleted_at=now,
                permanently_deleted_at=now,
                is_active=False,
                status="permanently_deleted",
            )
        )

    rider = await db.scalar(
        select(RiderProfile).where(
            RiderProfile.user_id == user_id, RiderProfile.deleted_at.is_(None)
        )
    )
    if rider:
        rider.deleted_at = now
        rider.status = "SUSPENDED"
        rider.available_delivery = False
        rider.available_rides = False
        rider.display_name = "Removed rider"
        rider.photo_url = None
        rider.nin = None
        rider.emergency_contact_name = None
        rider.emergency_contact_phone = None
        rider.plate_number = None
        rider.licence_number = None
        rider.motorcycle_reg = None
        rider.lat = None
        rider.lng = None

    if target.profile is not None:
        target.profile.first_name = None
        target.profile.last_name = None
        target.profile.username = None
        target.profile.avatar_url = None
        target.profile.bio = None
        target.profile.interests = None
        target.profile.owns_business = False
        target.profile.wants_to_ride = False

    target.phone = _tombstone_phone(user_id)
    target.email = None
    target.phone_verified = False
    target.email_verified = False
    target.status = UserStatus.DELETED.value
    target.role = "CUSTOMER"
    target.last_seen_at = None

    db.add(
        AuditLog(
            actor_id=actor.id,
            action="USER_DELETE",
            entity_type="user",
            entity_id=user_id,
            metadata_json={
                "reason": reason,
                "former_phone_suffix": original_phone[-4:] if original_phone else None,
            },
        )
    )
    await db.flush()
    return {"status": "deleted", "user_id": str(user_id)}


async def delete_own_account(db: AsyncSession, user: User) -> dict:
    if is_permanent_admin_phone(user.phone):
        raise HTTPException(status_code=400, detail="This admin account cannot be deleted")
    loaded = await db.scalar(
        select(User).options(selectinload(User.profile)).where(User.id == user.id)
    )
    assert loaded is not None
    return await purge_user_account(db, target=loaded, actor=loaded, reason="self")


async def admin_delete_user(db: AsyncSession, admin: User, user_id: uuid.UUID) -> dict:
    if user_id == admin.id:
        raise HTTPException(status_code=400, detail="Cannot delete your own admin account here")
    target = await db.scalar(
        select(User).options(selectinload(User.profile)).where(User.id == user_id)
    )
    if target is None:
        raise HTTPException(status_code=404, detail="User not found")
    return await purge_user_account(db, target=target, actor=admin, reason="admin")


async def apply_login_status_rules(db: AsyncSession, user: User) -> None:
    """Called after a successful OTP. Deleted stays out; deactivated comes back."""
    if user.status == UserStatus.DELETED.value:
        raise HTTPException(status_code=403, detail="This account was deleted")
    if user.status == UserStatus.SUSPENDED.value:
        raise HTTPException(
            status_code=403,
            detail="This account is suspended. Contact Wamu support.",
        )
    if user.status == UserStatus.DEACTIVATED.value:
        user.status = UserStatus.ACTIVE.value
        db.add(
            AuditLog(
                actor_id=user.id,
                action="USER_REACTIVATE",
                entity_type="user",
                entity_id=user.id,
                metadata_json={"status": UserStatus.ACTIVE.value},
            )
        )
        await db.flush()
