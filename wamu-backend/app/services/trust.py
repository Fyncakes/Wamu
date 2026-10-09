"""Peer block / trust helpers."""

from __future__ import annotations

import uuid

from fastapi import HTTPException
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.audit import AuditLog
from app.models.block import UserBlock
from app.models.user import User, UserStatus


async def is_blocked_either_way(
    db: AsyncSession, a: uuid.UUID, b: uuid.UUID
) -> bool:
    row = await db.scalar(
        select(UserBlock.id).where(
            or_(
                (UserBlock.blocker_id == a) & (UserBlock.blocked_id == b),
                (UserBlock.blocker_id == b) & (UserBlock.blocked_id == a),
            )
        )
    )
    return row is not None


async def assert_not_blocked(db: AsyncSession, a: uuid.UUID, b: uuid.UUID) -> None:
    if await is_blocked_either_way(db, a, b):
        raise HTTPException(status_code=403, detail="You cannot interact with this user")


async def block_user(db: AsyncSession, blocker: User, blocked_id: uuid.UUID) -> UserBlock:
    if blocked_id == blocker.id:
        raise HTTPException(status_code=400, detail="Cannot block yourself")
    peer = await db.get(User, blocked_id)
    if peer is None:
        raise HTTPException(status_code=404, detail="User not found")
    existing = await db.scalar(
        select(UserBlock).where(
            UserBlock.blocker_id == blocker.id, UserBlock.blocked_id == blocked_id
        )
    )
    if existing:
        return existing
    row = UserBlock(blocker_id=blocker.id, blocked_id=blocked_id)
    db.add(row)
    db.add(
        AuditLog(
            actor_id=blocker.id,
            action="USER_BLOCKED",
            entity_type="user",
            entity_id=blocked_id,
            metadata_json={},
        )
    )
    await db.flush()
    return row


async def unblock_user(db: AsyncSession, blocker: User, blocked_id: uuid.UUID) -> dict:
    row = await db.scalar(
        select(UserBlock).where(
            UserBlock.blocker_id == blocker.id, UserBlock.blocked_id == blocked_id
        )
    )
    if row:
        await db.delete(row)
        await db.flush()
    return {"status": "ok"}


async def list_blocked(db: AsyncSession, blocker: User) -> list[User]:
    result = await db.execute(
        select(User)
        .options(selectinload(User.profile))
        .join(UserBlock, UserBlock.blocked_id == User.id)
        .where(UserBlock.blocker_id == blocker.id)
        .order_by(UserBlock.created_at.desc())
    )
    return list(result.scalars().all())


async def admin_set_user_status(
    db: AsyncSession, admin: User, user_id: uuid.UUID, status: str
) -> User:
    if status not in {UserStatus.ACTIVE.value, UserStatus.SUSPENDED.value}:
        raise HTTPException(status_code=400, detail="Invalid status")
    user = await db.scalar(
        select(User).options(selectinload(User.profile)).where(User.id == user_id)
    )
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    if user.id == admin.id:
        raise HTTPException(status_code=400, detail="Cannot change your own status")
    user.status = status
    db.add(
        AuditLog(
            actor_id=admin.id,
            action="USER_SUSPEND" if status == UserStatus.SUSPENDED.value else "USER_ACTIVATE",
            entity_type="user",
            entity_id=user.id,
            metadata_json={"status": status},
        )
    )
    await db.flush()
    return user
