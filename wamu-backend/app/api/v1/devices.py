"""Device push-token registration."""

from __future__ import annotations

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, Field
from sqlalchemy import delete, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user
from app.models.device import DevicePushToken
from app.models.user import User

router = APIRouter()


class PushTokenUpsert(BaseModel):
    token: str = Field(min_length=8, max_length=512)
    platform: str = Field(default="android", pattern="^(android|ios|web)$")


class PushTokenResponse(BaseModel):
    token: str
    platform: str
    updated_at: datetime | None = None


@router.put("/push-token", response_model=PushTokenResponse)
async def upsert_push_token(
    body: PushTokenUpsert,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Register or refresh this device's FCM/APNs token for the current user."""
    token = body.token.strip()
    now = datetime.now(timezone.utc)

    async def _bind(row: DevicePushToken) -> DevicePushToken:
        row.user_id = user.id
        row.platform = body.platform
        row.updated_at = now
        return row

    existing = await db.scalar(
        select(DevicePushToken).where(DevicePushToken.token == token)
    )
    if existing:
        row = await _bind(existing)
        await db.flush()
    else:
        row = DevicePushToken(
            user_id=user.id,
            token=token,
            platform=body.platform,
            updated_at=now,
        )
        try:
            async with db.begin_nested():
                db.add(row)
                await db.flush()
        except IntegrityError:
            raced = await db.scalar(
                select(DevicePushToken).where(DevicePushToken.token == token)
            )
            if raced is None:
                raise
            row = await _bind(raced)
            await db.flush()
    return PushTokenResponse(
        token=row.token, platform=row.platform, updated_at=row.updated_at
    )


@router.delete("/push-token", status_code=204)
async def delete_push_token(
    token: str = Query(..., min_length=8, max_length=512),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await db.execute(
        delete(DevicePushToken).where(
            DevicePushToken.user_id == user.id,
            DevicePushToken.token == token,
        )
    )
    await db.flush()
    return None
