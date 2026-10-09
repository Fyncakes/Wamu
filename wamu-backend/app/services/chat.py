"""Chat service — peer DMs + business chats, enriched inbox, reactions."""

from __future__ import annotations

import logging
import uuid
from collections import Counter
from datetime import datetime, timezone

from fastapi import HTTPException
from sqlalchemy import and_, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.business import Business
from app.models.chat import Conversation, ConversationMember, Message, MessageHide, MessageReaction
from app.models.notification import Notification
from app.models.user import User
from app.schemas.commerce import ConversationCreate, MessageCreate
from app.services import presence as presence_service
from app.services.inbox_preview import message_preview_text, reaction_preview_text

logger = logging.getLogger(__name__)


def _visible_message_clause(user_id: uuid.UUID):
    hidden = select(MessageHide.message_id).where(MessageHide.user_id == user_id)
    return and_(Message.deleted_at.is_(None), Message.id.notin_(hidden))


def _enqueue_message_pushes(
    *,
    conversation_id: uuid.UUID,
    sender_id: uuid.UUID,
    members: list[ConversationMember],
) -> None:
    """Fire-and-forget data-only pushes — never include message plaintext."""
    try:
        from app.workers.tasks import send_push_notification

        for member in members:
            if member.user_id == sender_id:
                continue
            if getattr(member, "muted", False):
                continue
            send_push_notification.delay(
                str(member.user_id),
                "Wamu",
                "New message",
                {
                    "type": "NEW_MESSAGE",
                    "conversation_id": str(conversation_id),
                },
            )
    except Exception as exc:
        # Redis/Celery often down in local demo — don't dump full traceback every message.
        broker_down = False
        cur: BaseException | None = exc
        for _ in range(8):
            if cur is None:
                break
            if isinstance(cur, ConnectionRefusedError) or "Connection refused" in str(cur):
                broker_down = True
                break
            cur = cur.__cause__ or cur.__context__
        if broker_down:
            logger.warning(
                "Push skipped (broker unavailable) conversation_id=%s", conversation_id
            )
        else:
            logger.exception(
                "Failed to enqueue push conversation_id=%s", conversation_id
            )


def _display_name(user: User | None) -> str:
    if not user:
        return "Wamu user"
    if user.profile:
        parts = [user.profile.first_name or "", user.profile.last_name or ""]
        name = " ".join(p for p in parts if p).strip()
        if name:
            return name
        if user.profile.username:
            return f"@{user.profile.username}"
    return user.phone


def _profile_avatar(user: User | None) -> str | None:
    if not user or not user.profile:
        return None
    url = (user.profile.avatar_url or "").strip()
    return url or None


async def _conversation_avatars(
    db: AsyncSession,
    *,
    viewer: User,
    convo: Conversation,
    peer: User | None = None,
    business: Business | None = None,
) -> tuple[str | None, list[str]]:
    """Profile / shop photos for inbox + chat header (initials if empty)."""
    urls: list[str] = []
    if convo.type == "DIRECT":
        url = _profile_avatar(peer)
        if url:
            urls.append(url)
    elif convo.business_id:
        biz = business or await db.get(Business, convo.business_id)
        logo = (biz.logo_url or "").strip() if biz else ""
        if logo:
            urls.append(logo)
    elif convo.type == "GROUP":
        member_ids = [m.user_id for m in convo.members if m.user_id != viewer.id]
        if member_ids:
            result = await db.execute(
                select(User)
                .options(selectinload(User.profile))
                .where(User.id.in_(member_ids))
            )
            for other in result.scalars().all():
                url = _profile_avatar(other)
                if url:
                    urls.append(url)
                if len(urls) >= 4:
                    break
    return (urls[0] if urls else None, urls)


def _reactions_map(msg: Message) -> dict[str, int]:
    return dict(Counter(r.emoji for r in (msg.reactions or [])))


def _can_send_read_receipt(user: User, convo: Conversation) -> bool:
    """WhatsApp-style: privacy toggle applies to 1:1; groups always send READ."""
    if convo.type == "GROUP":
        return True
    if user.profile is None:
        return True
    return bool(getattr(user.profile, "show_read_receipts", True))


def _mask_status_for_viewer(
    status: str,
    *,
    sender_id: uuid.UUID,
    viewer: User,
    convo_type: str | None,
) -> str:
    """If viewer hid receipts, don't show blue ✓✓ on their own outbound DMs."""
    if status != "READ":
        return status
    if convo_type == "GROUP":
        return status
    if sender_id != viewer.id:
        return status
    if viewer.profile is not None and not getattr(
        viewer.profile, "show_read_receipts", True
    ):
        return "DELIVERED"
    return status


def serialize_message(
    msg: Message,
    *,
    viewer: User | None = None,
    convo_type: str | None = None,
) -> dict:
    reply_preview = None
    if msg.reply_to is not None:
        reply_preview = {
            "id": msg.reply_to.id,
            "body": (msg.reply_to.body or "")[:160],
            "sender_id": msg.reply_to.sender_id,
            "message_type": msg.reply_to.message_type,
        }
    elif msg.reply_to_message_id is not None:
        # Fallback when reply_to wasn't eagerly loaded
        reply_preview = None
    status = msg.status
    if viewer is not None:
        status = _mask_status_for_viewer(
            status or "SENT",
            sender_id=msg.sender_id,
            viewer=viewer,
            convo_type=convo_type,
        )
    return {
        "id": msg.id,
        "conversation_id": msg.conversation_id,
        "sender_id": msg.sender_id,
        "body": msg.body,
        "message_type": msg.message_type,
        "media_url": msg.media_url,
        "client_message_id": msg.client_message_id,
        "status": status,
        "created_at": msg.created_at,
        "reactions": _reactions_map(msg),
        "reply_to_message_id": msg.reply_to_message_id,
        "reply_to": reply_preview,
    }


async def start_conversation(
    db: AsyncSession, user: User, data: ConversationCreate
) -> Conversation:
    if data.business_id:
        return await _start_business_chat(db, user, data)
    if data.peer_user_id or (data.peer_phone and data.peer_phone.strip()):
        return await _start_direct_chat(db, user, data)
    raise HTTPException(
        status_code=400,
        detail="Provide business_id, peer_user_id, or peer_phone",
    )


async def _start_business_chat(
    db: AsyncSession, user: User, data: ConversationCreate
) -> Conversation:
    business = await db.get(Business, data.business_id)
    if not business or business.deleted_at:
        raise HTTPException(status_code=404, detail="Business not found")

    result = await db.execute(
        select(Conversation)
        .join(ConversationMember)
        .where(
            Conversation.business_id == data.business_id,
            ConversationMember.user_id == user.id,
        )
        .options(selectinload(Conversation.members))
    )
    existing = result.scalars().first()
    if existing:
        if data.initial_message:
            await send_message(
                db, user, existing.id, MessageCreate(body=data.initial_message)
            )
        return existing

    convo = Conversation(business_id=data.business_id, type="CUSTOMER_BUSINESS")
    db.add(convo)
    await db.flush()
    db.add(ConversationMember(conversation_id=convo.id, user_id=user.id))
    if business.owner_id != user.id:
        db.add(ConversationMember(conversation_id=convo.id, user_id=business.owner_id))
    await db.flush()
    if data.initial_message:
        await send_message(db, user, convo.id, MessageCreate(body=data.initial_message))
    return await get_conversation(db, convo.id, user)


async def _start_direct_chat(
    db: AsyncSession, user: User, data: ConversationCreate
) -> Conversation:
    peer: User | None = None
    if data.peer_user_id:
        peer = await db.get(User, data.peer_user_id)
    elif data.peer_phone:
        phone = data.peer_phone.strip()
        peer = await db.scalar(select(User).where(User.phone == phone))
    if not peer:
        raise HTTPException(status_code=404, detail="User not found on Wamu")
    if peer.id == user.id:
        raise HTTPException(status_code=400, detail="Cannot chat with yourself")

    from app.services.trust import assert_not_blocked

    await assert_not_blocked(db, user.id, peer.id)

    # Find existing DIRECT conversation between the two users
    result = await db.execute(
        select(Conversation)
        .join(ConversationMember)
        .where(
            Conversation.type == "DIRECT",
            ConversationMember.user_id == user.id,
        )
        .options(selectinload(Conversation.members))
    )
    for convo in result.scalars().unique().all():
        member_ids = {m.user_id for m in convo.members}
        if peer.id in member_ids and user.id in member_ids and len(member_ids) == 2:
            mine = next((m for m in convo.members if m.user_id == user.id), None)
            if mine is not None:
                mine.hidden_at = None
            if data.initial_message:
                await send_message(
                    db, user, convo.id, MessageCreate(body=data.initial_message)
                )
            return convo

    convo = Conversation(type="DIRECT", business_id=None)
    db.add(convo)
    await db.flush()
    db.add(ConversationMember(conversation_id=convo.id, user_id=user.id))
    db.add(ConversationMember(conversation_id=convo.id, user_id=peer.id))
    await db.flush()
    if data.initial_message:
        await send_message(db, user, convo.id, MessageCreate(body=data.initial_message))
    return await get_conversation(db, convo.id, user)


async def get_conversation(
    db: AsyncSession, conversation_id: uuid.UUID, user: User
) -> Conversation:
    result = await db.execute(
        select(Conversation)
        .options(selectinload(Conversation.members))
        .where(Conversation.id == conversation_id)
    )
    convo = result.scalar_one_or_none()
    if not convo:
        raise HTTPException(status_code=404, detail="Conversation not found")
    if not any(m.user_id == user.id for m in convo.members) and user.role != "ADMIN":
        raise HTTPException(status_code=403, detail="Not a member")
    return convo


async def list_conversations(db: AsyncSession, user: User) -> list[dict]:
    result = await db.execute(
        select(Conversation, ConversationMember)
        .join(ConversationMember)
        .where(
            ConversationMember.user_id == user.id,
            ConversationMember.hidden_at.is_(None),
        )
        .options(selectinload(Conversation.members))
        .order_by(Conversation.last_message_at.desc().nullslast())
    )
    rows = []
    for convo, member in result.unique().all():
        peer_name = None
        peer_phone = None
        peer_user_id = None
        peer = None
        biz = None
        if convo.type == "DIRECT":
            peer_member = next((m for m in convo.members if m.user_id != user.id), None)
            if peer_member:
                peer = await db.scalar(
                    select(User)
                    .options(selectinload(User.profile))
                    .where(User.id == peer_member.user_id)
                )
                if peer:
                    peer_name = _display_name(peer)
                    peer_phone = peer.phone
                    peer_user_id = peer.id
        elif convo.type == "GROUP":
            peer_name = convo.title or "Group"
        elif convo.business_id:
            biz = await db.get(Business, convo.business_id)
            peer_name = biz.name if biz else "Business"
        avatar_url, avatar_urls = await _conversation_avatars(
            db, viewer=user, convo=convo, peer=peer, business=biz
        )

        last_preview = None
        last_from_me = False
        last_status = None
        last_msg = await db.scalar(
            select(Message)
            .where(
                Message.conversation_id == convo.id,
                _visible_message_clause(user.id),
            )
            .order_by(Message.created_at.desc())
            .limit(1)
        )
        if last_msg:
            last_preview = message_preview_text(last_msg)
            last_from_me = last_msg.sender_id == user.id
            last_status = _mask_status_for_viewer(
                last_msg.status or "SENT",
                sender_id=last_msg.sender_id,
                viewer=user,
                convo_type=convo.type,
            )

        # Newer reaction wins the subtitle (WhatsApp-style scan density).
        rx_row = (
            await db.execute(
                select(MessageReaction, Message, User)
                .join(Message, Message.id == MessageReaction.message_id)
                .join(User, User.id == MessageReaction.user_id)
                .where(
                    Message.conversation_id == convo.id,
                    _visible_message_clause(user.id),
                )
                .options(selectinload(User.profile))
                .order_by(MessageReaction.created_at.desc())
                .limit(1)
            )
        ).first()
        if rx_row is not None:
            reaction, reacted_msg, reactor = rx_row
            use_reaction = last_msg is None or (
                reaction.created_at is not None
                and last_msg.created_at is not None
                and reaction.created_at >= last_msg.created_at
            )
            if use_reaction:
                last_preview = reaction_preview_text(
                    reactor_is_me=reactor.id == user.id,
                    reactor_name=_display_name(reactor),
                    emoji=reaction.emoji,
                    message_body=reacted_msg.body,
                )
                last_from_me = reactor.id == user.id
                last_status = None

        peer_presence = {"peer_online": False, "peer_last_seen_at": None}
        if peer_user_id:
            peer_presence = await presence_service.load_peer_presence(
                db, peer_user_id, viewer=user
            )

        rows.append(
            {
                "id": convo.id,
                "type": convo.type,
                "business_id": convo.business_id,
                "last_message_at": convo.last_message_at,
                "unread_count": member.unread_count,
                "participant_name": peer_name,
                "participant_phone": peer_phone,
                "peer_user_id": peer_user_id,
                "participant_avatar_url": avatar_url,
                "participant_avatar_urls": avatar_urls,
                "last_message_preview": last_preview,
                "last_message_from_me": last_from_me,
                "last_message_status": last_status,
                "title": convo.title,
                "community_slug": convo.community_slug,
                "member_count": len(convo.members),
                "muted": bool(member.muted),
                "pinned": bool(getattr(member, "pinned", False)),
                "archived": bool(getattr(member, "archived", False)),
                "favourite": bool(getattr(member, "favourite", False)),
                **peer_presence,
            }
        )
    # Pinned chats float to the top within non-archived list order
    rows.sort(
        key=lambda r: (
            0 if r.get("pinned") else 1,
            -(r["last_message_at"].timestamp() if r.get("last_message_at") else 0),
        )
    )
    return rows


async def update_conversation_prefs(
    db: AsyncSession,
    user: User,
    conversation_id: uuid.UUID,
    *,
    muted: bool | None = None,
    pinned: bool | None = None,
    archived: bool | None = None,
    favourite: bool | None = None,
) -> dict:
    await get_conversation(db, conversation_id, user)
    member = await db.scalar(
        select(ConversationMember).where(
            ConversationMember.conversation_id == conversation_id,
            ConversationMember.user_id == user.id,
        )
    )
    if not member:
        raise HTTPException(status_code=403, detail="Not a member")
    if muted is not None:
        member.muted = muted
    if pinned is not None:
        member.pinned = pinned
    if archived is not None:
        member.archived = archived
    if favourite is not None:
        member.favourite = favourite
    await db.flush()
    convo = await get_conversation(db, conversation_id, user)
    return await _conversation_row(db, user, convo)


async def hide_conversation(
    db: AsyncSession, user: User, conversation_id: uuid.UUID
) -> dict:
    """Remove the thread from this user's inbox only. No peer alert."""
    await get_conversation(db, conversation_id, user)
    member = await db.scalar(
        select(ConversationMember).where(
            ConversationMember.conversation_id == conversation_id,
            ConversationMember.user_id == user.id,
        )
    )
    if not member:
        raise HTTPException(status_code=403, detail="Not a member")
    member.hidden_at = datetime.now(timezone.utc)
    member.unread_count = 0
    await db.flush()
    return {"ok": True, "conversation_id": str(conversation_id)}


async def list_members(db: AsyncSession, user: User, conversation_id: uuid.UUID) -> list[dict]:
    convo = await get_conversation(db, conversation_id, user)
    out: list[dict] = []
    for m in convo.members:
        peer = await db.scalar(
            select(User).options(selectinload(User.profile)).where(User.id == m.user_id)
        )
        if not peer:
            continue
        out.append(
            {
                "user_id": str(peer.id),
                "name": _display_name(peer),
                "phone": peer.phone,
                "avatar_url": peer.profile.avatar_url if peer.profile else None,
                "is_me": peer.id == user.id,
                "member_role": getattr(m, "member_role", None) or "MEMBER",
            }
        )
    out.sort(key=lambda r: (0 if r["is_me"] else 1, r["name"].lower()))
    return out


async def leave_conversation(db: AsyncSession, user: User, conversation_id: uuid.UUID) -> dict:
    convo = await get_conversation(db, conversation_id, user)
    if convo.type != "GROUP":
        raise HTTPException(status_code=400, detail="Only group chats can be left")
    member = await db.scalar(
        select(ConversationMember).where(
            ConversationMember.conversation_id == conversation_id,
            ConversationMember.user_id == user.id,
        )
    )
    if not member:
        raise HTTPException(status_code=403, detail="Not a member")
    await send_message(
        db,
        user,
        conversation_id,
        MessageCreate(body=f"{_display_name(user)} left the group", message_type="SYSTEM"),
    )
    await db.delete(member)
    await db.flush()
    return {"ok": True, "conversation_id": str(conversation_id)}


async def kick_member(
    db: AsyncSession,
    actor: User,
    conversation_id: uuid.UUID,
    target_user_id: uuid.UUID,
) -> dict:
    convo = await get_conversation(db, conversation_id, actor)
    if convo.type != "GROUP":
        raise HTTPException(status_code=400, detail="Only group chats support kick")
    if target_user_id == actor.id:
        raise HTTPException(status_code=400, detail="Use leave to exit yourself")

    actor_member = await db.scalar(
        select(ConversationMember).where(
            ConversationMember.conversation_id == conversation_id,
            ConversationMember.user_id == actor.id,
        )
    )
    if not actor_member or actor_member.member_role != "ADMIN":
        raise HTTPException(status_code=403, detail="Only group admins can kick members")

    target = await db.scalar(
        select(ConversationMember).where(
            ConversationMember.conversation_id == conversation_id,
            ConversationMember.user_id == target_user_id,
        )
    )
    if not target:
        raise HTTPException(status_code=404, detail="Member not found")

    target_user = await db.get(User, target_user_id)
    await send_message(
        db,
        actor,
        conversation_id,
        MessageCreate(
            body=f"{_display_name(actor)} removed {_display_name(target_user)}",
            message_type="SYSTEM",
        ),
    )
    await db.delete(target)
    await db.flush()
    return {"ok": True, "conversation_id": str(conversation_id), "kicked": str(target_user_id)}


async def rename_conversation(
    db: AsyncSession, user: User, conversation_id: uuid.UUID, title: str
) -> dict:
    convo = await get_conversation(db, conversation_id, user)
    if convo.type != "GROUP":
        raise HTTPException(status_code=400, detail="Only groups can be renamed")
    clean = title.strip()
    if len(clean) < 2 or len(clean) > 200:
        raise HTTPException(status_code=400, detail="Title must be 2–200 characters")
    convo.title = clean
    await db.flush()
    await send_message(
        db,
        user,
        conversation_id,
        MessageCreate(body=f"{_display_name(user)} renamed the group to “{clean}”", message_type="SYSTEM"),
    )
    return await _conversation_row(db, user, await get_conversation(db, conversation_id, user))


async def send_message(
    db: AsyncSession, user: User, conversation_id: uuid.UUID, data: MessageCreate
) -> Message:
    msg_type = (data.message_type or "TEXT").upper()
    body = (data.body or "").strip()
    if msg_type in ("IMAGE", "VOICE", "DOCUMENT") and not data.media_url:
        raise HTTPException(status_code=400, detail="media_url required for media messages")
    if msg_type == "TEXT" and not body:
        raise HTTPException(status_code=400, detail="Message too short")
    if msg_type == "ORDER_CARD" and not body:
        raise HTTPException(status_code=400, detail="ORDER_CARD body required")
    if len(body) > 4000:
        raise HTTPException(status_code=400, detail="Message too long")
    if not body:
        if msg_type == "IMAGE":
            body = "📷 Photo"
        elif msg_type == "VOICE":
            body = "🎤 Voice note"
        elif msg_type == "DOCUMENT":
            body = "📄 Document"
        elif msg_type == "ORDER_CARD":
            body = "🛒 Order"
        else:
            body = "Message"

    convo = await get_conversation(db, conversation_id, user)

    if convo.type == "DIRECT":
        from app.services.trust import assert_not_blocked

        for member in convo.members:
            if member.user_id != user.id:
                await assert_not_blocked(db, user.id, member.user_id)

    client_id = (data.client_message_id or "").strip() or None
    if client_id and len(client_id) > 80:
        raise HTTPException(status_code=400, detail="client_message_id too long")
    if client_id:
        existing = await db.scalar(
            select(Message)
            .options(selectinload(Message.reactions), selectinload(Message.reply_to))
            .where(
                Message.conversation_id == convo.id,
                Message.sender_id == user.id,
                Message.client_message_id == client_id,
                Message.deleted_at.is_(None),
            )
        )
        if existing:
            return existing

    reply_to_id = data.reply_to_message_id
    if reply_to_id:
        parent = await db.get(Message, reply_to_id)
        if not parent or parent.conversation_id != convo.id or parent.deleted_at:
            raise HTTPException(status_code=400, detail="Invalid reply target")

    msg = Message(
        conversation_id=convo.id,
        sender_id=user.id,
        body=body,
        message_type=msg_type,
        media_url=data.media_url,
        client_message_id=client_id,
        status="SENT",
        reply_to_message_id=reply_to_id,
    )
    db.add(msg)
    convo.last_message_at = datetime.now(timezone.utc)
    preview = body[:120]
    for member in convo.members:
        member.hidden_at = None
        if member.user_id != user.id:
            member.unread_count += 1
            db.add(
                Notification(
                    user_id=member.user_id,
                    type="NEW_MESSAGE",
                    title="New Wamu chat",
                    body=preview,
                    data={"conversation_id": str(convo.id)},
                )
            )
    try:
        await db.flush()
    except IntegrityError:
        # Race: concurrent retry with same client_message_id
        if not client_id:
            raise
        await db.rollback()
        existing = await db.scalar(
            select(Message)
            .options(selectinload(Message.reactions), selectinload(Message.reply_to))
            .where(
                Message.conversation_id == conversation_id,
                Message.sender_id == user.id,
                Message.client_message_id == client_id,
                Message.deleted_at.is_(None),
            )
        )
        if existing:
            return existing
        raise
    _enqueue_message_pushes(
        conversation_id=convo.id,
        sender_id=user.id,
        members=list(convo.members),
    )
    result = await db.execute(
        select(Message)
        .options(selectinload(Message.reactions), selectinload(Message.reply_to))
        .where(Message.id == msg.id)
    )
    return result.scalar_one()


async def list_messages(
    db: AsyncSession, user: User, conversation_id: uuid.UUID, limit: int = 50
) -> tuple[list[Message], list[uuid.UUID], str | None, str]:
    """
    Returns messages + ids newly status-updated + status applied + convo type.
    When the reader has read receipts off (1:1), caps at DELIVERED.
    """
    convo = await get_conversation(db, conversation_id, user)
    result = await db.execute(
        select(Message)
        .where(
            Message.conversation_id == conversation_id,
            _visible_message_clause(user.id),
        )
        .options(selectinload(Message.reactions), selectinload(Message.reply_to))
        .order_by(Message.created_at.desc())
        .limit(min(limit, 100))
    )
    member = await db.scalar(
        select(ConversationMember).where(
            ConversationMember.conversation_id == conversation_id,
            ConversationMember.user_id == user.id,
        )
    )
    newly_ids: list[uuid.UUID] = []
    applied: str | None = None
    if member:
        member.unread_count = 0
        target = "READ" if _can_send_read_receipt(user, convo) else "DELIVERED"
        rank = {"SENT": 0, "DELIVERED": 1, "READ": 2}
        target_rank = rank[target]
        pending = await db.execute(
            select(Message.id, Message.status).where(
                and_(
                    Message.conversation_id == conversation_id,
                    Message.sender_id != user.id,
                    Message.status != target,
                )
            )
        )
        to_upgrade = [
            mid
            for mid, st in pending.all()
            if rank.get(st or "SENT", 0) < target_rank
        ]
        if to_upgrade:
            await db.execute(
                update(Message).where(Message.id.in_(to_upgrade)).values(status=target)
            )
            newly_ids = to_upgrade
            applied = target
        await db.flush()
    return list(reversed(result.scalars().all())), newly_ids, applied, convo.type


async def acknowledge_message(
    db: AsyncSession, user: User, message_id: uuid.UUID, status: str
) -> Message:
    status = status.upper()
    if status not in ("DELIVERED", "READ"):
        raise HTTPException(status_code=400, detail="status must be DELIVERED or READ")
    msg = await db.get(Message, message_id)
    if not msg or msg.deleted_at:
        raise HTTPException(status_code=404, detail="Message not found")
    convo = await get_conversation(db, msg.conversation_id, user)
    if msg.sender_id == user.id:
        raise HTTPException(status_code=400, detail="Cannot ack own message")

    if status == "READ" and not _can_send_read_receipt(user, convo):
        status = "DELIVERED"

    rank = {"SENT": 0, "DELIVERED": 1, "READ": 2}
    current = rank.get(msg.status, 0)
    target = rank[status]
    if target > current:
        msg.status = status
        await db.flush()
    result = await db.execute(
        select(Message)
        .options(selectinload(Message.reactions), selectinload(Message.reply_to))
        .where(Message.id == message_id)
    )
    return result.scalar_one()


async def react_to_message(
    db: AsyncSession, user: User, message_id: uuid.UUID, emoji: str
) -> Message:
    msg = await db.get(Message, message_id)
    if not msg or msg.deleted_at:
        raise HTTPException(status_code=404, detail="Message not found")
    await get_conversation(db, msg.conversation_id, user)

    existing = await db.scalar(
        select(MessageReaction).where(
            MessageReaction.message_id == message_id,
            MessageReaction.user_id == user.id,
            MessageReaction.emoji == emoji,
        )
    )
    if existing:
        await db.delete(existing)
    else:
        db.add(MessageReaction(message_id=message_id, user_id=user.id, emoji=emoji))
        convo = await db.get(Conversation, msg.conversation_id)
        if convo is not None:
            convo.last_message_at = datetime.now(timezone.utc)
    await db.flush()
    result = await db.execute(
        select(Message)
        .options(selectinload(Message.reactions), selectinload(Message.reply_to))
        .where(Message.id == message_id)
    )
    return result.scalar_one()


async def hide_messages_for_me(
    db: AsyncSession,
    user: User,
    conversation_id: uuid.UUID,
    message_ids: list[uuid.UUID],
) -> list[uuid.UUID]:
    """Hide selected messages for this user only. No peer event."""
    if not message_ids:
        return []
    await get_conversation(db, conversation_id, user)
    result = await db.execute(
        select(Message).where(
            Message.conversation_id == conversation_id,
            Message.id.in_(message_ids),
            Message.deleted_at.is_(None),
        )
    )
    hidden: list[uuid.UUID] = []
    for msg in result.scalars().all():
        existing = await db.scalar(
            select(MessageHide.id).where(
                MessageHide.message_id == msg.id,
                MessageHide.user_id == user.id,
            )
        )
        if existing is None:
            db.add(MessageHide(message_id=msg.id, user_id=user.id))
        hidden.append(msg.id)
    if hidden:
        await db.flush()
    return hidden


async def soft_delete_messages(
    db: AsyncSession,
    user: User,
    conversation_id: uuid.UUID,
    message_ids: list[uuid.UUID],
) -> list[uuid.UUID]:
    """Silent unsend of own messages. Returns ids that were deleted."""
    if not message_ids:
        return []
    await get_conversation(db, conversation_id, user)
    now = datetime.now(timezone.utc)
    result = await db.execute(
        select(Message).where(
            Message.conversation_id == conversation_id,
            Message.id.in_(message_ids),
            Message.deleted_at.is_(None),
            Message.sender_id == user.id,
        )
    )
    deleted: list[uuid.UUID] = []
    for msg in result.scalars().all():
        msg.deleted_at = now
        deleted.append(msg.id)
    if deleted:
        await db.flush()
    return deleted


async def lookup_user_by_phone(db: AsyncSession, phone: str) -> dict | None:
    user = await db.scalar(
        select(User).options(selectinload(User.profile)).where(User.phone == phone)
    )
    if not user:
        return None
    return {
        "id": user.id,
        "phone": user.phone,
        "name": _display_name(user),
        "username": user.profile.username if user.profile else None,
        "avatar_url": user.profile.avatar_url if user.profile else None,
    }


async def list_directory(db: AsyncSession, user: User, limit: int = 40) -> dict:
    """Directory of other Wamu users for contact picker."""
    from app.services.trust import is_blocked_either_way

    result = await db.execute(
        select(User)
        .options(selectinload(User.profile))
        .where(User.id != user.id, User.status == "ACTIVE")
        .order_by(User.created_at.desc())
        .limit(min(limit, 100))
    )
    people = []
    for peer in result.scalars().all():
        if await is_blocked_either_way(db, user.id, peer.id):
            continue
        people.append(
            {
                "id": str(peer.id),
                "phone": peer.phone,
                "name": _display_name(peer),
                "username": peer.profile.username if peer.profile else None,
                "avatar_url": peer.profile.avatar_url if peer.profile else None,
                "on_wamu": True,
            }
        )
    return {
        "items": people,
        "on_wamu_count": len(people),
        "note": "Invite friends who are not on Wamu yet",
    }


async def _conversation_row(db: AsyncSession, user: User, convo: Conversation) -> dict:
    rows = await list_conversations(db, user)
    for row in rows:
        if row["id"] == convo.id:
            return row
    return {
        "id": convo.id,
        "type": convo.type,
        "business_id": convo.business_id,
        "last_message_at": convo.last_message_at,
        "unread_count": 0,
        "participant_name": convo.title or "Group",
        "participant_avatar_url": None,
        "participant_avatar_urls": [],
        "title": convo.title,
        "community_slug": convo.community_slug,
        "member_count": len(convo.members),
        "muted": False,
        "pinned": False,
        "archived": False,
        "favourite": False,
        "peer_online": False,
        "peer_last_seen_at": None,
    }


async def join_community_group(
    db: AsyncSession,
    user: User,
    *,
    slug: str,
    title: str,
    welcome: str | None = None,
) -> Conversation:
    """Join curated Uganda community — creates the GROUP once, then adds members."""
    existing = await db.scalar(
        select(Conversation)
        .where(Conversation.type == "GROUP", Conversation.community_slug == slug)
        .options(selectinload(Conversation.members))
    )
    if existing:
        if not any(m.user_id == user.id for m in existing.members):
            db.add(ConversationMember(conversation_id=existing.id, user_id=user.id))
            await db.flush()
            await send_message(
                db,
                user,
                existing.id,
                MessageCreate(body=f"{_display_name(user)} joined the crew 👋", message_type="SYSTEM"),
            )
        return await get_conversation(db, existing.id, user)

    convo = Conversation(type="GROUP", title=title, community_slug=slug)
    db.add(convo)
    await db.flush()
    db.add(ConversationMember(conversation_id=convo.id, user_id=user.id, member_role="ADMIN"))
    await db.flush()
    body = welcome or f"Welcome to {title} — keep it respectful, keep it Ugandan 🇺🇬"
    await send_message(db, user, convo.id, MessageCreate(body=body, message_type="SYSTEM"))
    return await get_conversation(db, convo.id, user)


async def leave_community_group(db: AsyncSession, user: User, *, slug: str) -> dict:
    """Leave a curated community GROUP by slug."""
    convo = await db.scalar(
        select(Conversation)
        .where(Conversation.type == "GROUP", Conversation.community_slug == slug)
        .options(selectinload(Conversation.members))
    )
    if not convo:
        raise HTTPException(status_code=404, detail="Community chat not found")
    return await leave_conversation(db, user, convo.id)


async def create_group(
    db: AsyncSession,
    user: User,
    *,
    title: str,
    member_phones: list[str],
    initial_message: str | None = None,
) -> Conversation:
    title = title.strip()
    if len(title) < 2:
        raise HTTPException(status_code=400, detail="Group name too short")

    convo = Conversation(type="GROUP", title=title)
    db.add(convo)
    await db.flush()
    db.add(ConversationMember(conversation_id=convo.id, user_id=user.id, member_role="ADMIN"))

    added: set[uuid.UUID] = {user.id}
    for raw in member_phones:
        phone = (raw or "").strip()
        if not phone:
            continue
        peer = await db.scalar(select(User).where(User.phone == phone))
        if peer and peer.id not in added:
            from app.services.trust import assert_not_blocked

            await assert_not_blocked(db, user.id, peer.id)
            db.add(
                ConversationMember(
                    conversation_id=convo.id, user_id=peer.id, member_role="MEMBER"
                )
            )
            added.add(peer.id)
    await db.flush()

    opener = initial_message or f"{_display_name(user)} created “{title}”"
    await send_message(db, user, convo.id, MessageCreate(body=opener, message_type="SYSTEM"))
    return await get_conversation(db, convo.id, user)
