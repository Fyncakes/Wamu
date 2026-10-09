"""
Redis-backed rate limiting (OTP abuse + general API).

Falls back to in-memory counters when Redis is unavailable (local tests).
"""

from __future__ import annotations

import time
from collections import defaultdict
from threading import Lock

import redis.asyncio as redis

from app.core.config import get_settings

settings = get_settings()

_memory: dict[str, list[float]] = defaultdict(list)
_lock = Lock()
_redis: redis.Redis | None = None


async def get_redis() -> redis.Redis | None:
    global _redis
    if _redis is not None:
        return _redis
    try:
        client = redis.from_url(settings.redis_url, decode_responses=True)
        await client.ping()
        _redis = client
        return _redis
    except Exception:
        return None


async def is_rate_limited(key: str, limit: int, window_seconds: int) -> bool:
    """Return True if the caller should be blocked."""
    client = await get_redis()
    now = time.time()
    if client is not None:
        pipe = client.pipeline()
        redis_key = f"rl:{key}"
        pipe.zremrangebyscore(redis_key, 0, now - window_seconds)
        pipe.zadd(redis_key, {str(now): now})
        pipe.zcard(redis_key)
        pipe.expire(redis_key, window_seconds)
        results = await pipe.execute()
        count = results[2]
        return count > limit

    with _lock:
        bucket = _memory[key]
        cutoff = now - window_seconds
        _memory[key] = [t for t in bucket if t >= cutoff]
        _memory[key].append(now)
        return len(_memory[key]) > limit
