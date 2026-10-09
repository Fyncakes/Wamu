"""Chat REST + WebSocket realtime channel — messaging-first Wamu."""

from __future__ import annotations

import json
import logging
from uuid import UUID

from fastapi import APIRouter, Depends, Query, WebSocket, WebSocketDisconnect
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import AsyncSessionLocal, get_db
from app.core.deps import get_current_user
from app.core.metrics import WS_CHAT_CONNECT, WS_CHAT_DISCONNECT, metrics
from app.core.realtime import manager
from app.core.security import create_ws_ticket, decode_access_token, decode_ws_ticket
from app.models.user import User
from app.schemas.commerce import (
    ConversationCreate,
    ConversationPrefsUpdate,
    ConversationRename,
    ConversationResponse,
    MessageAck,
    MessageBulkDelete,
    MessageCreate,
    MessageReactionCreate,
    MessageResponse,
)
from app.services import chat as chat_service
from app.services import presence as presence_service

logger = logging.getLogger(__name__)
router = APIRouter()


class WsTicketRequest(BaseModel):
    conversation_id: UUID


class WsTicketResponse(BaseModel):
    ticket: str
    expires_in: int
    conversation_id: UUID


async def _emit_presence(conversation_id: str, user_id: UUID, *, online: bool) -> None:
    last_seen = None
    show_online = True
    show_last = True
    async with AsyncSessionLocal() as db:
        from sqlalchemy import select
        from sqlalchemy.orm import selectinload

        user = await db.scalar(
            select(User).options(selectinload(User.profile)).where(User.id == user_id)
        )
        if user:
            last_seen = await presence_service.touch_last_seen(db, user_id)
            await db.commit()
            if user.profile is not None:
                show_online = bool(getattr(user.profile, "show_online", True))
                show_last = bool(getattr(user.profile, "show_last_seen", True))
    visible_online = online and show_online
    await manager.broadcast(
        str(conversation_id),
        {
            "event": "presence.updated",
            "user_id": str(user_id),
            "conversation_id": str(conversation_id),
            "online": visible_online,
            "last_seen_at": last_seen.isoformat() if (show_last and last_seen) else None,
        },
    )


def _message_response(msg, *, viewer=None, convo_type: str | None = None) -> MessageResponse:
    data = chat_service.serialize_message(msg, viewer=viewer, convo_type=convo_type)
    return MessageResponse.model_validate(data)


@router.post("/conversations", response_model=ConversationResponse, status_code=201)
async def start_conversation(
    body: ConversationCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    convo = await chat_service.start_conversation(db, user, body)
    rows = await chat_service.list_conversations(db, user)
    for row in rows:
        if row["id"] == convo.id:
            return ConversationResponse.model_validate(row)
    unread = 0
    for m in convo.members:
        if m.user_id == user.id:
            unread = m.unread_count
    return ConversationResponse(
        id=convo.id,
        type=convo.type,
        business_id=convo.business_id,
        last_message_at=convo.last_message_at,
        unread_count=unread,
    )


@router.get("/conversations", response_model=list[ConversationResponse])
async def list_conversations(
    user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)
):
    rows = await chat_service.list_conversations(db, user)
    return [ConversationResponse.model_validate(r) for r in rows]


@router.get("/conversations/{conversation_id}", response_model=ConversationResponse)
async def get_conversation(
    conversation_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    convo = await chat_service.get_conversation(db, conversation_id, user)
    row = await chat_service._conversation_row(db, user, convo)
    return ConversationResponse.model_validate(row)


@router.patch("/conversations/{conversation_id}/prefs", response_model=ConversationResponse)
async def update_conversation_prefs(
    conversation_id: UUID,
    body: ConversationPrefsUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    row = await chat_service.update_conversation_prefs(
        db,
        user,
        conversation_id,
        muted=body.muted,
        pinned=body.pinned,
        archived=body.archived,
        favourite=body.favourite,
    )
    return ConversationResponse.model_validate(row)


@router.post("/conversations/{conversation_id}/hide")
async def hide_conversation(
    conversation_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await chat_service.hide_conversation(db, user, conversation_id)


@router.get("/conversations/{conversation_id}/members")
async def list_conversation_members(
    conversation_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    items = await chat_service.list_members(db, user, conversation_id)
    return {"items": items, "count": len(items)}


@router.post("/conversations/{conversation_id}/leave")
async def leave_conversation(
    conversation_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await chat_service.leave_conversation(db, user, conversation_id)


@router.post("/conversations/{conversation_id}/kick/{user_id}")
async def kick_member(
    conversation_id: UUID,
    user_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await chat_service.kick_member(db, user, conversation_id, user_id)


@router.patch("/conversations/{conversation_id}", response_model=ConversationResponse)
async def rename_conversation(
    conversation_id: UUID,
    body: ConversationRename,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    row = await chat_service.rename_conversation(db, user, conversation_id, body.title)
    return ConversationResponse.model_validate(row)


@router.get("/users/lookup")
async def lookup_user(
    phone: str = Query(..., min_length=10, max_length=20),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    found = await chat_service.lookup_user_by_phone(db, phone.strip())
    if not found:
        from fastapi import HTTPException

        raise HTTPException(status_code=404, detail="No Wamu user with that phone")
    return found


@router.get("/directory")
async def contact_directory(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """People on Wamu for the contact picker (Sprint 3)."""
    return await chat_service.list_directory(db, user)


@router.get("/conversations/{conversation_id}/messages", response_model=list[MessageResponse])
async def list_messages(
    conversation_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    msgs, newly_ids, applied, convo_type = await chat_service.list_messages(
        db, user, conversation_id
    )
    if newly_ids and applied:
        await manager.broadcast(
            str(conversation_id),
            {
                "event": "message.status",
                "ids": [str(i) for i in newly_ids],
                "status": applied,
            },
        )
    return [
        _message_response(m, viewer=user, convo_type=convo_type) for m in msgs
    ]


@router.post(
    "/conversations/{conversation_id}/messages",
    response_model=MessageResponse,
    status_code=201,
)
async def send_message(
    conversation_id: UUID,
    body: MessageCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    msg = await chat_service.send_message(db, user, conversation_id, body)
    convo = await chat_service.get_conversation(db, conversation_id, user)
    resp = _message_response(msg, viewer=user, convo_type=convo.type)
    await manager.broadcast(
        str(conversation_id),
        {"event": "message.new", **resp.model_dump(mode="json")},
    )
    return resp


@router.post("/messages/{message_id}/ack", response_model=MessageResponse)
async def ack_message(
    message_id: UUID,
    body: MessageAck,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    msg = await chat_service.acknowledge_message(db, user, message_id, body.status)
    convo = await chat_service.get_conversation(db, msg.conversation_id, user)
    resp = _message_response(msg, viewer=user, convo_type=convo.type)
    await manager.broadcast(
        str(msg.conversation_id),
        {
            "event": "message.status",
            "ids": [str(msg.id)],
            "status": msg.status,
        },
    )
    return resp


@router.post("/messages/{message_id}/reactions", response_model=MessageResponse)
async def react(
    message_id: UUID,
    body: MessageReactionCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    msg = await chat_service.react_to_message(db, user, message_id, body.emoji)
    resp = _message_response(msg)
    await manager.broadcast(
        str(msg.conversation_id),
        {"event": "message.reaction", **resp.model_dump(mode="json")},
    )
    return resp


@router.post("/conversations/{conversation_id}/messages/delete")
async def delete_messages(
    conversation_id: UUID,
    body: MessageBulkDelete,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    deleted: list = []
    if body.scope == "me":
        deleted = await chat_service.hide_messages_for_me(
            db, user, conversation_id, body.message_ids
        )
    else:
        deleted = await chat_service.soft_delete_messages(
            db, user, conversation_id, body.message_ids
        )
        if deleted:
            await manager.broadcast(
                str(conversation_id),
                {
                    "event": "message.deleted",
                    "ids": [str(mid) for mid in deleted],
                },
            )
    return {"deleted_ids": [str(mid) for mid in deleted], "count": len(deleted)}


@router.post("/ws-ticket", response_model=WsTicketResponse)
async def issue_ws_ticket(
    body: WsTicketRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """
    Issue a short-lived WS ticket after verifying conversation membership.
    Prefer `?ticket=` over putting the long-lived access JWT in the WS URL.
    """
    from app.core.config import get_settings

    await chat_service.get_conversation(db, body.conversation_id, user)
    ticket = create_ws_ticket(
        user.id, scope="chat", conversation_id=body.conversation_id
    )
    return WsTicketResponse(
        ticket=ticket,
        expires_in=get_settings().ws_ticket_expire_seconds,
        conversation_id=body.conversation_id,
    )


@router.websocket("/ws/{conversation_id}")
async def chat_ws(
    websocket: WebSocket,
    conversation_id: UUID,
    ticket: str | None = None,
    token: str | None = None,
):
    """
    Connect with `?ticket=<ws_ticket>` (preferred) from POST /chat/ws-ticket.
    Legacy `?token=<access_jwt>` still accepted in non-production for older clients.
    Membership is always verified before accept.
    """
    from app.core.config import get_settings

    user_id: UUID | None = None
    try:
        if ticket:
            payload = decode_ws_ticket(ticket, expected_scope="chat")
            user_id = UUID(payload["sub"])
            claimed = payload.get("conversation_id")
            if claimed and claimed != str(conversation_id):
                await websocket.close(code=4403)
                return
        elif token:
            if get_settings().is_production:
                await websocket.close(code=4401)
                return
            logger.warning("Deprecated WS auth via access token query param")
            payload = decode_access_token(token)
            user_id = UUID(payload["sub"])
        else:
            await websocket.close(code=4401)
            return
    except Exception:
        await websocket.close(code=4401)
        return

    # Membership gate — never subscribe strangers to a room
    async with AsyncSessionLocal() as db:
        user = await db.get(User, user_id)
        if not user:
            await websocket.close(code=4401)
            return
        try:
            await chat_service.get_conversation(db, conversation_id, user)
        except Exception:
            await websocket.close(code=4403)
            return

    await manager.connect(str(conversation_id), websocket)
    metrics.incr(WS_CHAT_CONNECT)
    await presence_service.mark_online(user_id)
    await _emit_presence(str(conversation_id), user_id, online=True)

    try:
        while True:
            raw = await websocket.receive_text()
            data = json.loads(raw)
            event = data.get("event")
            if event in ("typing.started", "typing.stopped"):
                await manager.broadcast(
                    str(conversation_id),
                    {
                        "event": event,
                        "user_id": str(user_id),
                        "conversation_id": str(conversation_id),
                    },
                )
                continue
            if event == "presence.ping":
                await presence_service.refresh_presence(user_id)
                async with AsyncSessionLocal() as db:
                    await presence_service.touch_last_seen(db, user_id)
                    await db.commit()
                continue

            body = (data.get("body") or "").strip()
            if not body:
                continue
            async with AsyncSessionLocal() as db:
                user = await db.get(User, user_id)
                if not user:
                    continue
                msg = await chat_service.send_message(
                    db,
                    user,
                    conversation_id,
                    MessageCreate(
                        body=body,
                        message_type=data.get("message_type", "TEXT"),
                        media_url=data.get("media_url"),
                        reply_to_message_id=data.get("reply_to_message_id"),
                        client_message_id=data.get("client_message_id"),
                    ),
                )
                await db.commit()
                resp = _message_response(msg)
                await manager.broadcast(
                    str(conversation_id),
                    {"event": "message.new", **resp.model_dump(mode="json")},
                )
    except WebSocketDisconnect:
        pass
    except Exception:
        pass
    finally:
        manager.disconnect(str(conversation_id), websocket)
        metrics.incr(WS_CHAT_DISCONNECT)
        became_offline = await presence_service.mark_offline(user_id)
        if became_offline:
            await _emit_presence(str(conversation_id), user_id, online=False)
