"""Voice/video call REST + user signaling WebSocket."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, WebSocket, WebSocketDisconnect
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.database import AsyncSessionLocal, get_db
from app.core.deps import get_current_user
from app.core.metrics import WS_CALLS_CONNECT, WS_CALLS_DISCONNECT, metrics
from app.core.security import create_ws_ticket, decode_access_token, decode_ws_ticket
from app.models.call import CallSession
from app.models.chat import Conversation
from app.models.notification import Notification
from app.models.user import User
from app.services.chat import _display_name
from app.services.ice import build_ice_servers

router = APIRouter()


class CallsWsTicketResponse(BaseModel):
    ticket: str
    expires_in: int


class IceServer(BaseModel):
    urls: str
    username: str | None = None
    credential: str | None = None


class UserSignalHub:
    """Fan-out signaling frames to a user's connected devices."""

    def __init__(self) -> None:
        self.active: dict[str, list[WebSocket]] = {}

    async def connect(self, user_id: str, websocket: WebSocket) -> None:
        await websocket.accept()
        self.active.setdefault(user_id, []).append(websocket)

    def disconnect(self, user_id: str, websocket: WebSocket) -> None:
        conns = self.active.get(user_id, [])
        if websocket in conns:
            conns.remove(websocket)

    async def send(self, user_id: str, payload: dict) -> None:
        for ws in list(self.active.get(user_id, [])):
            try:
                await ws.send_json(payload)
            except Exception:
                self.disconnect(user_id, ws)


hub = UserSignalHub()


class CallCreate(BaseModel):
    callee_id: UUID | None = None
    conversation_id: UUID | None = None
    call_type: str = Field(default="VOICE", pattern="^(VOICE|VIDEO)$")


class CallResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    caller_id: UUID
    callee_id: UUID
    conversation_id: UUID | None
    call_type: str
    status: str
    created_at: datetime
    answered_at: datetime | None = None
    ended_at: datetime | None = None
    peer_name: str | None = None
    direction: str | None = None  # OUTGOING | INCOMING
    ice_servers: list[IceServer] = Field(default_factory=list)


def _serialize(call: CallSession, *, me: User, peer: User | None) -> dict:
    direction = "OUTGOING" if call.caller_id == me.id else "INCOMING"
    return {
        "id": call.id,
        "caller_id": call.caller_id,
        "callee_id": call.callee_id,
        "conversation_id": call.conversation_id,
        "call_type": call.call_type,
        "status": call.status,
        "created_at": call.created_at,
        "answered_at": call.answered_at,
        "ended_at": call.ended_at,
        "peer_name": _display_name(peer),
        "direction": direction,
        "ice_servers": build_ice_servers(),
    }


async def _peer_for(db: AsyncSession, call: CallSession, me: User) -> User | None:
    peer_id = call.callee_id if call.caller_id == me.id else call.caller_id
    return await db.scalar(
        select(User).options(selectinload(User.profile)).where(User.id == peer_id)
    )


async def _resolve_callee(
    db: AsyncSession, user: User, body: CallCreate
) -> tuple[UUID, UUID | None]:
    if body.callee_id:
        if body.callee_id == user.id:
            raise HTTPException(status_code=400, detail="Cannot call yourself")
        peer = await db.get(User, body.callee_id)
        if not peer:
            raise HTTPException(status_code=404, detail="User not found")
        return peer.id, body.conversation_id

    if body.conversation_id:
        result = await db.execute(
            select(Conversation)
            .options(selectinload(Conversation.members))
            .where(Conversation.id == body.conversation_id)
        )
        convo = result.scalar_one_or_none()
        if not convo:
            raise HTTPException(status_code=404, detail="Conversation not found")
        if not any(m.user_id == user.id for m in convo.members):
            raise HTTPException(status_code=403, detail="Not a member")
        if convo.type != "DIRECT":
            raise HTTPException(status_code=400, detail="Calls are 1:1 for now — use a DM")
        peer_member = next((m for m in convo.members if m.user_id != user.id), None)
        if not peer_member:
            raise HTTPException(status_code=400, detail="No peer in conversation")
        return peer_member.user_id, convo.id

    raise HTTPException(status_code=400, detail="Provide callee_id or conversation_id")


@router.post("", response_model=CallResponse, status_code=201)
async def start_call(
    body: CallCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    callee_id, conversation_id = await _resolve_callee(db, user, body)
    call = CallSession(
        caller_id=user.id,
        callee_id=callee_id,
        conversation_id=conversation_id,
        call_type=body.call_type,
        status="RINGING",
    )
    db.add(call)
    await db.flush()
    db.add(
        Notification(
            user_id=callee_id,
            type="INCOMING_CALL",
            title=f"Incoming {body.call_type.lower()} call",
            body=f"{_display_name(user)} is calling on Wamu",
            data={"call_id": str(call.id), "call_type": body.call_type},
        )
    )
    await db.flush()
    peer = await _peer_for(db, call, user)
    resp = CallResponse.model_validate(_serialize(call, me=user, peer=peer))
    await hub.send(
        str(callee_id),
        {
            "event": "call.incoming",
            **resp.model_dump(mode="json"),
            "caller_name": _display_name(user),
        },
    )
    return resp


@router.get("/history", response_model=list[CallResponse])
async def call_history(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(CallSession)
        .where(or_(CallSession.caller_id == user.id, CallSession.callee_id == user.id))
        .order_by(CallSession.created_at.desc())
        .limit(50)
    )
    calls = result.scalars().all()
    out: list[CallResponse] = []
    for call in calls:
        peer = await _peer_for(db, call, user)
        out.append(CallResponse.model_validate(_serialize(call, me=user, peer=peer)))
    return out


@router.get("/{call_id}", response_model=CallResponse)
async def get_call(
    call_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    call = await db.get(CallSession, call_id)
    if not call or user.id not in (call.caller_id, call.callee_id):
        raise HTTPException(status_code=404, detail="Call not found")
    peer = await _peer_for(db, call, user)
    return CallResponse.model_validate(_serialize(call, me=user, peer=peer))


@router.post("/{call_id}/accept", response_model=CallResponse)
async def accept_call(
    call_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    call = await db.get(CallSession, call_id)
    if not call or call.callee_id != user.id:
        raise HTTPException(status_code=404, detail="Call not found")
    if call.status != "RINGING":
        raise HTTPException(status_code=400, detail=f"Cannot accept call in {call.status}")
    call.status = "ACCEPTED"
    call.answered_at = datetime.now(timezone.utc)
    await db.flush()
    peer = await _peer_for(db, call, user)
    resp = CallResponse.model_validate(_serialize(call, me=user, peer=peer))
    await hub.send(str(call.caller_id), {"event": "call.accepted", **resp.model_dump(mode="json")})
    return resp


@router.post("/{call_id}/reject", response_model=CallResponse)
async def reject_call(
    call_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    call = await db.get(CallSession, call_id)
    if not call or call.callee_id != user.id:
        raise HTTPException(status_code=404, detail="Call not found")
    call.status = "REJECTED"
    call.ended_at = datetime.now(timezone.utc)
    await db.flush()
    peer = await _peer_for(db, call, user)
    resp = CallResponse.model_validate(_serialize(call, me=user, peer=peer))
    await hub.send(str(call.caller_id), {"event": "call.rejected", **resp.model_dump(mode="json")})
    return resp


@router.post("/{call_id}/end", response_model=CallResponse)
async def end_call(
    call_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    call = await db.get(CallSession, call_id)
    if not call or user.id not in (call.caller_id, call.callee_id):
        raise HTTPException(status_code=404, detail="Call not found")
    if call.status == "RINGING" and call.caller_id == user.id:
        call.status = "CANCELLED"
    elif call.status == "RINGING" and call.callee_id == user.id:
        call.status = "MISSED"
    else:
        call.status = "ENDED"
    call.ended_at = datetime.now(timezone.utc)
    await db.flush()
    peer = await _peer_for(db, call, user)
    resp = CallResponse.model_validate(_serialize(call, me=user, peer=peer))
    other = call.callee_id if user.id == call.caller_id else call.caller_id
    await hub.send(str(other), {"event": "call.ended", **resp.model_dump(mode="json")})
    return resp


@router.post("/ws-ticket", response_model=CallsWsTicketResponse)
async def issue_calls_ws_ticket(user: User = Depends(get_current_user)):
    from app.core.config import get_settings

    ticket = create_ws_ticket(user.id, scope="calls")
    return CallsWsTicketResponse(
        ticket=ticket,
        expires_in=get_settings().ws_ticket_expire_seconds,
    )


@router.websocket("/ws")
async def calls_ws(
    websocket: WebSocket,
    ticket: str | None = None,
    token: str | None = None,
):
    """
    User signaling socket. Prefer `?ticket=` from POST /calls/ws-ticket.
    Legacy `?token=<access_jwt>` allowed only outside production.
    """
    import logging

    from app.core.config import get_settings

    log = logging.getLogger(__name__)
    try:
        if ticket:
            payload = decode_ws_ticket(ticket, expected_scope="calls")
            user_id = str(UUID(payload["sub"]))
        elif token:
            if get_settings().is_production:
                await websocket.close(code=4401)
                return
            log.warning("Deprecated calls WS auth via access token query param")
            payload = decode_access_token(token)
            user_id = str(UUID(payload["sub"]))
        else:
            await websocket.close(code=4401)
            return
    except Exception:
        await websocket.close(code=4401)
        return

    await hub.connect(user_id, websocket)
    metrics.incr(WS_CALLS_CONNECT)
    try:
        while True:
            raw = await websocket.receive_text()
            data = json.loads(raw)
            if data.get("event") != "signal":
                continue
            to_user = data.get("to_user_id")
            call_id = data.get("call_id")
            signal = data.get("data") or {}
            if not to_user or not call_id:
                continue
            # Light auth: caller/callee must own the call
            async with AsyncSessionLocal() as db:
                call = await db.get(CallSession, UUID(str(call_id)))
                if not call or user_id not in (str(call.caller_id), str(call.callee_id)):
                    continue
                if to_user not in (str(call.caller_id), str(call.callee_id)):
                    continue
            await hub.send(
                str(to_user),
                {
                    "event": "signal",
                    "call_id": str(call_id),
                    "from_user_id": user_id,
                    "data": signal,
                },
            )
    except WebSocketDisconnect:
        pass
    except Exception:
        pass
    finally:
        hub.disconnect(user_id, websocket)
        metrics.incr(WS_CALLS_DISCONNECT)
