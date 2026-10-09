"""
Realtime fan-out for chat WebSockets.

Local connections stay in-process; publishes go through Redis when available so
multiple API workers can deliver the same event. Falls back to local-only when
Redis is down (single-node / local demo).
"""

from __future__ import annotations

import asyncio
import json
import logging
from typing import Any

from fastapi import WebSocket

from app.core.config import get_settings
from app.core.rate_limit import get_redis

logger = logging.getLogger(__name__)
settings = get_settings()

CHANNEL_PREFIX = "wamu:chat:"


class ConnectionManager:
    def __init__(self) -> None:
        self.active: dict[str, list[WebSocket]] = {}
        self._listener_task: asyncio.Task | None = None
        self._started = False

    async def start(self) -> None:
        if self._started or not settings.realtime_use_redis:
            return
        self._started = True
        self._listener_task = asyncio.create_task(self._listen_redis())

    async def stop(self) -> None:
        if self._listener_task:
            self._listener_task.cancel()
            try:
                await self._listener_task
            except asyncio.CancelledError:
                pass
            self._listener_task = None
        self._started = False

    async def connect(self, conversation_id: str, websocket: WebSocket) -> None:
        await websocket.accept()
        self.active.setdefault(conversation_id, []).append(websocket)

    def disconnect(self, conversation_id: str, websocket: WebSocket) -> None:
        conns = self.active.get(conversation_id, [])
        if websocket in conns:
            conns.remove(websocket)
        if not conns:
            self.active.pop(conversation_id, None)

    async def broadcast(self, conversation_id: str, payload: dict[str, Any]) -> None:
        """Publish to Redis (if up) and deliver to local sockets."""
        published = False
        if settings.realtime_use_redis:
            client = await get_redis()
            if client is not None:
                try:
                    await client.publish(
                        f"{CHANNEL_PREFIX}{conversation_id}",
                        json.dumps(payload, default=str),
                    )
                    published = True
                except Exception:
                    logger.exception("Redis publish failed; falling back to local")
        if not published:
            await self._deliver_local(conversation_id, payload)

    async def _deliver_local(self, conversation_id: str, payload: dict[str, Any]) -> None:
        for ws in list(self.active.get(conversation_id, [])):
            try:
                await ws.send_json(payload)
            except Exception:
                self.disconnect(conversation_id, ws)

    async def _listen_redis(self) -> None:
        while True:
            client = await get_redis()
            if client is None:
                await asyncio.sleep(2)
                continue
            try:
                pubsub = client.pubsub()
                await pubsub.psubscribe(f"{CHANNEL_PREFIX}*")
                logger.info("Realtime Redis listener subscribed to %s*", CHANNEL_PREFIX)
                async for message in pubsub.listen():
                    if message is None:
                        continue
                    if message.get("type") not in ("pmessage", "message"):
                        continue
                    channel = message.get("channel") or ""
                    if isinstance(channel, bytes):
                        channel = channel.decode()
                    if not channel.startswith(CHANNEL_PREFIX):
                        continue
                    conversation_id = channel[len(CHANNEL_PREFIX) :]
                    data = message.get("data")
                    if isinstance(data, bytes):
                        data = data.decode()
                    if not isinstance(data, str):
                        continue
                    try:
                        payload = json.loads(data)
                    except json.JSONDecodeError:
                        continue
                    await self._deliver_local(conversation_id, payload)
            except asyncio.CancelledError:
                raise
            except Exception:
                logger.exception("Redis realtime listener error; retrying")
                await asyncio.sleep(2)


manager = ConnectionManager()
