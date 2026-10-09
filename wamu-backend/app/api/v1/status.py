"""Status / Stories API — 24h ephemeral updates for Uganda youth engagement."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.database import get_db
from app.core.deps import get_current_user
from app.models.chat import Conversation, ConversationMember
from app.models.status import StatusUpdate
from app.models.user import User
from app.services.chat import _display_name

router = APIRouter()


class StatusCreate(BaseModel):
    body: str = Field(min_length=1, max_length=500)
    media_type: str = "TEXT"
    media_url: str | None = None
    background_color: str | None = "#0B6E4F"
    audience: str = "CONTACTS"  # CONTACTS | EVERYONE


class StatusResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    user_id: UUID
    user_name: str
    media_type: str
    body: str | None
    media_url: str | None
    background_color: str | None
    audience: str = "CONTACTS"
    created_at: datetime
    expires_at: datetime
    is_mine: bool = False


async def _contact_user_ids(db: AsyncSession, user_id: UUID) -> set[UUID]:
    """Users who share a DIRECT conversation with me (plus myself)."""
    result = await db.execute(
        select(Conversation.id)
        .join(ConversationMember)
        .where(
            Conversation.type == "DIRECT",
            ConversationMember.user_id == user_id,
        )
    )
    convo_ids = list(result.scalars().all())
    if not convo_ids:
        return {user_id}
    peers = await db.execute(
        select(ConversationMember.user_id).where(
            ConversationMember.conversation_id.in_(convo_ids)
        )
    )
    return set(peers.scalars().all()) | {user_id}


@router.get("", response_model=list[StatusResponse])
async def list_statuses(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    now = datetime.now(timezone.utc)
    contacts = await _contact_user_ids(db, user.id)
    result = await db.execute(
        select(StatusUpdate)
        .where(StatusUpdate.expires_at > now)
        .order_by(StatusUpdate.created_at.desc())
        .limit(200)
    )
    rows = result.scalars().all()
    out: list[StatusResponse] = []
    for s in rows:
        audience = (s.audience or "CONTACTS").upper()
        if s.user_id != user.id:
            if audience == "CONTACTS" and s.user_id not in contacts:
                continue
            # EVERYONE visible to all authenticated users
        author = await db.scalar(
            select(User).options(selectinload(User.profile)).where(User.id == s.user_id)
        )
        out.append(
            StatusResponse(
                id=s.id,
                user_id=s.user_id,
                user_name=_display_name(author),
                media_type=s.media_type,
                body=s.body,
                media_url=s.media_url,
                background_color=s.background_color,
                audience=audience,
                created_at=s.created_at,
                expires_at=s.expires_at,
                is_mine=s.user_id == user.id,
            )
        )
    return out[:100]


@router.post("", response_model=StatusResponse, status_code=201)
async def create_status(
    body: StatusCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    audience = (body.audience or "CONTACTS").upper()
    if audience not in {"CONTACTS", "EVERYONE"}:
        raise HTTPException(status_code=400, detail="audience must be CONTACTS or EVERYONE")
    media_type = (body.media_type or "TEXT").upper()
    if media_type not in {"TEXT", "IMAGE"}:
        raise HTTPException(status_code=400, detail="media_type must be TEXT or IMAGE for beta")
    now = datetime.now(timezone.utc)
    status = StatusUpdate(
        user_id=user.id,
        media_type=media_type,
        body=body.body,
        media_url=body.media_url,
        background_color=body.background_color or "#0B6E4F",
        audience=audience,
        expires_at=now + timedelta(hours=24),
    )
    db.add(status)
    await db.flush()
    await db.refresh(status)
    author = await db.scalar(
        select(User).options(selectinload(User.profile)).where(User.id == user.id)
    )
    return StatusResponse(
        id=status.id,
        user_id=status.user_id,
        user_name=_display_name(author),
        media_type=status.media_type,
        body=status.body,
        media_url=status.media_url,
        background_color=status.background_color,
        audience=status.audience,
        created_at=status.created_at,
        expires_at=status.expires_at,
        is_mine=True,
    )
