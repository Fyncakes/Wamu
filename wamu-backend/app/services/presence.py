"""
Presence registry — online status + last_seen helpers.

Multi-instance: Redis keys `wamu:presence:{user_id}` with TTL heartbeat when
`realtime_use_redis` is on. Falls back to process-local counters otherwise.
last_seen stays in Postgres (`User.last_seen_at`).
"""

from __future__ import annotations

import logging
import uuid
from datetime import datetime, timezone

from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.user import User

logger = logging.getLogger(__name__)

PRESENCE_PREFIX = "wamu:presence:"

# user_id -> active socket count (local fallback only)
_online_counts: dict[str, int] = {}


async def _redis_client():
    from app.core.config import get_settings
    from app.core.rate_limit import get_redis

    if not get_settings().realtime_use_redis:
        return None
    return await get_redis()


def _ttl() -> int:
    from app.core.config import get_settings

    return max(30, int(get_settings().presence_ttl_seconds))


def _mem_mark_online(key: str) -> bool:
    prev = _online_counts.get(key, 0)
    _online_counts[key] = prev + 1
    return prev == 0


def _mem_mark_offline(key: str) -> bool:
    prev = _online_counts.get(key, 0)
    if prev <= 1:
        _online_counts.pop(key, None)
        return prev > 0
    _online_counts[key] = prev - 1
    return False


def _mem_is_online(key: str) -> bool:
    return _online_counts.get(key, 0) > 0


async def mark_online(user_id: str | uuid.UUID) -> bool:
    """Increment presence; returns True if newly online."""
    key = str(user_id)
    redis_key = f"{PRESENCE_PREFIX}{key}"
    client = await _redis_client()
    if client is not None:
        try:
            pipe = client.pipeline()
            pipe.incr(redis_key)
            pipe.expire(redis_key, _ttl())
            n, _ = await pipe.execute()
            return int(n) == 1
        except Exception:
            logger.exception("presence mark_online redis failed user_id=%s", key)
    return _mem_mark_online(key)


async def mark_offline(user_id: str | uuid.UUID) -> bool:
    """Decrement presence; returns True if now fully offline."""
    key = str(user_id)
    redis_key = f"{PRESENCE_PREFIX}{key}"
    client = await _redis_client()
    if client is not None:
        try:
            n = int(await client.decr(redis_key))
            if n <= 0:
                await client.delete(redis_key)
                return True
            await client.expire(redis_key, _ttl())
            return False
        except Exception:
            logger.exception("presence mark_offline redis failed user_id=%s", key)
    return _mem_mark_offline(key)


async def is_online(user_id: str | uuid.UUID) -> bool:
    key = str(user_id)
    redis_key = f"{PRESENCE_PREFIX}{key}"
    client = await _redis_client()
    if client is not None:
        try:
            raw = await client.get(redis_key)
            return int(raw or 0) > 0
        except Exception:
            logger.exception("presence is_online redis failed user_id=%s", key)
    return _mem_is_online(key)


async def refresh_presence(user_id: str | uuid.UUID) -> None:
    """Extend Redis TTL on heartbeat (presence.ping). No-op for memory path."""
    key = str(user_id)
    redis_key = f"{PRESENCE_PREFIX}{key}"
    client = await _redis_client()
    if client is None:
        return
    try:
        await client.expire(redis_key, _ttl())
    except Exception:
        logger.exception("presence refresh redis failed user_id=%s", key)


async def touch_last_seen(db: AsyncSession, user_id: uuid.UUID) -> datetime:
    now = datetime.now(timezone.utc)
    user = await db.get(User, user_id)
    if user:
        user.last_seen_at = now
        await db.flush()
    return now


async def public_presence(peer: User | None, viewer: User | None = None) -> dict:
    """
    Presence fields visible to another user.

    WhatsApp-style reciprocity: if the viewer hid last-seen / online, they
    also do not see those fields for peers (peer privacy still applies first).
    """
    if not peer:
        return {"peer_online": False, "peer_last_seen_at": None}
    show_online = True
    show_last = True
    if peer.profile is not None:
        show_online = bool(getattr(peer.profile, "show_online", True))
        show_last = bool(getattr(peer.profile, "show_last_seen", True))

    viewer_wants_online = True
    viewer_wants_last = True
    if viewer is not None and viewer.profile is not None:
        viewer_wants_online = bool(getattr(viewer.profile, "show_online", True))
        viewer_wants_last = bool(getattr(viewer.profile, "show_last_seen", True))

    online = (await is_online(peer.id)) and show_online and viewer_wants_online
    last_seen = peer.last_seen_at if (show_last and viewer_wants_last) else None
    return {
        "peer_online": online,
        "peer_last_seen_at": last_seen,
    }


async def load_peer_presence(
    db: AsyncSession,
    peer_user_id: uuid.UUID | None,
    *,
    viewer: User | None = None,
) -> dict:
    if not peer_user_id:
        return {"peer_online": False, "peer_last_seen_at": None}
    from sqlalchemy import select

    peer = await db.scalar(
        select(User).options(selectinload(User.profile)).where(User.id == peer_user_id)
    )
    return await public_presence(peer, viewer=viewer)


def reset_memory_presence() -> None:
    """Test helper — clear process-local counters."""
    _online_counts.clear()
