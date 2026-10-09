"""Uganda communities — curated discovery that joins real GROUP chats."""

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.database import get_db
from app.core.deps import get_current_user
from app.models.chat import Conversation, ConversationMember
from app.models.user import User
from app.schemas.commerce import ConversationResponse, GroupCreate
from app.services import chat as chat_service

router = APIRouter()

UGANDA_COMMUNITIES = [
    {
        "id": "kampala-campus",
        "name": "Kampala Campus",
        "city": "Kampala",
        "members_label": "Open community",
        "tagline": "Makerere, Kyambogo, UCU vibes — notes, hangouts, hustles",
        "topics": ["Students", "Events", "Jobs"],
        "color": "#0B6E4F",
        "welcome": "Kampala Campus is live — share notes, hangouts, and hustles. No spam.",
        "channel": True,
    },
    {
        "id": "gulu-creatives",
        "name": "Northern Creatives",
        "city": "Gulu",
        "members_label": "Open community",
        "tagline": "Music, design, and content creators across the North",
        "topics": ["Music", "Design", "Content"],
        "color": "#C45C26",
        "welcome": "Northern Creatives — drop your art, music, and collabs.",
        "channel": False,
    },
    {
        "id": "mbarara-hustle",
        "name": "Mbarara Hustle Hub",
        "city": "Mbarara",
        "members_label": "Open community",
        "tagline": "Side hustles, boda tips, and small business chat",
        "topics": ["Business", "Jobs"],
        "color": "#1B4F72",
        "welcome": "Mbarara Hustle Hub — tips, gigs, and small business wins.",
        "channel": False,
    },
    {
        "id": "entebbe-nightlife",
        "name": "Entebbe & Lakeside",
        "city": "Entebbe",
        "members_label": "Open community",
        "tagline": "Weekend plans, beach days, and safe meetups",
        "topics": ["Hangouts", "Safety"],
        "color": "#6C3483",
        "welcome": "Entebbe & Lakeside — plan safe weekend vibes.",
        "channel": False,
    },
    {
        "id": "uganda-football",
        "name": "Uganda Cranes",
        "city": "Nationwide",
        "members_label": "Open channel",
        "tagline": "Cranes scores, watch parties, match-day energy",
        "topics": ["Sports", "Cranes"],
        "color": "#117A65",
        "welcome": "Uganda Cranes channel — scores and watch parties, no toxicity.",
        "channel": True,
    },
    {
        "id": "church-youth",
        "name": "Faith & Fellowship",
        "city": "Nationwide",
        "members_label": "Open community",
        "tagline": "Youth groups, worship nights, community service",
        "topics": ["Faith", "Community"],
        "color": "#7D3C98",
        "welcome": "Faith & Fellowship — encourage, serve, and connect.",
        "channel": True,
    },
]

_BY_ID = {c["id"]: c for c in UGANDA_COMMUNITIES}


def _members_label(n: int, *, channel: bool) -> str:
    if n <= 0:
        return "Be the first" if not channel else "Open channel"
    if n == 1:
        return "1 member"
    return f"{n} members"


async def _enrich_communities(db: AsyncSession, user: User, catalog: list[dict]) -> list[dict]:
    counts_rows = (
        await db.execute(
            select(Conversation.community_slug, func.count(ConversationMember.id))
            .join(ConversationMember, ConversationMember.conversation_id == Conversation.id)
            .where(Conversation.community_slug.is_not(None))
            .group_by(Conversation.community_slug)
        )
    ).all()
    counts = {slug: int(n) for slug, n in counts_rows if slug}

    joined_rows = (
        await db.execute(
            select(Conversation.community_slug)
            .join(ConversationMember, ConversationMember.conversation_id == Conversation.id)
            .where(
                Conversation.community_slug.is_not(None),
                ConversationMember.user_id == user.id,
            )
        )
    ).all()
    joined = {row[0] for row in joined_rows if row[0]}

    items: list[dict] = []
    for c in catalog:
        item = dict(c)
        n = counts.get(c["id"], 0)
        item["member_count"] = n
        item["members_label"] = _members_label(n, channel=bool(c.get("channel")))
        item["joined"] = c["id"] in joined
        items.append(item)
    return items


@router.get("")
async def list_communities(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    items = await _enrich_communities(db, user, UGANDA_COMMUNITIES)
    return {"items": items, "note": "Join opens a live group chat"}


@router.get("/channels")
async def list_channels(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Broadcast-style channels for Updates tab (Sprint 3)."""
    channels = [c for c in UGANDA_COMMUNITIES if c.get("channel")]
    items = await _enrich_communities(db, user, channels)
    return {
        "items": items,
        "note": "Follow opens the live channel chat — same spine as Communities",
    }


@router.post("/groups", response_model=ConversationResponse, status_code=201)
async def create_group(
    body: GroupCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    convo = await chat_service.create_group(
        db,
        user,
        title=body.title,
        member_phones=body.member_phones,
        initial_message=body.initial_message,
    )
    row = await chat_service._conversation_row(db, user, convo)
    return ConversationResponse.model_validate(row)


@router.post("/{community_id}/join", response_model=ConversationResponse)
async def join_community(
    community_id: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    meta = _BY_ID.get(community_id)
    if not meta:
        raise HTTPException(status_code=404, detail="Community not found")
    convo = await chat_service.join_community_group(
        db,
        user,
        slug=community_id,
        title=meta["name"],
        welcome=meta.get("welcome"),
    )
    # Ensure members are loaded for accurate member_count in response.
    convo = await db.scalar(
        select(Conversation)
        .where(Conversation.id == convo.id)
        .options(selectinload(Conversation.members))
    )
    row = await chat_service._conversation_row(db, user, convo)
    return ConversationResponse.model_validate(row)


@router.post("/{community_id}/leave")
async def leave_community(
    community_id: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    meta = _BY_ID.get(community_id)
    if not meta:
        raise HTTPException(status_code=404, detail="Community not found")
    return await chat_service.leave_community_group(db, user, slug=community_id)
