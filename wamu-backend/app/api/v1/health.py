from __future__ import annotations

import time

from fastapi import APIRouter
from sqlalchemy import text

from app.core.config import get_settings
from app.core.database import engine
from app.core.metrics import metrics
from app.core.rate_limit import get_redis
from app.services.staging_readiness import rails_readiness

router = APIRouter()
settings = get_settings()
_STARTED_AT = time.monotonic()


@router.get("/health")
async def health():
    return {
        "status": "ok",
        "app": settings.app_name,
        "environment": settings.environment,
        "version": settings.app_version,
        "uptime_seconds": int(time.monotonic() - _STARTED_AT),
        # Client UX flags — no secrets. Testers see honest copy for OTP/pay.
        "otp_mock": settings.otp_mock_mode,
        "payment_mock": settings.payment_mock_auto_success,
    }


@router.get("/health/database")
async def health_database():
    t0 = time.perf_counter()
    try:
        async with engine.connect() as conn:
            await conn.execute(text("SELECT 1"))
        return {
            "status": "ok",
            "latency_ms": round((time.perf_counter() - t0) * 1000, 2),
        }
    except Exception as exc:
        return {
            "status": "error",
            "detail": str(exc),
            "latency_ms": round((time.perf_counter() - t0) * 1000, 2),
        }


@router.get("/health/redis")
async def health_redis():
    t0 = time.perf_counter()
    client = await get_redis()
    if client is None:
        return {
            "status": "degraded",
            "detail": "redis unavailable; using memory fallback",
            "latency_ms": round((time.perf_counter() - t0) * 1000, 2),
        }
    try:
        await client.ping()
        return {
            "status": "ok",
            "latency_ms": round((time.perf_counter() - t0) * 1000, 2),
        }
    except Exception as exc:
        return {
            "status": "error",
            "detail": str(exc),
            "latency_ms": round((time.perf_counter() - t0) * 1000, 2),
        }


@router.get("/health/rails")
async def health_rails():
    """
    Payment / push / WebRTC rail readiness (booleans only — no secrets).

    Use before MoMo sandbox or TURN phone tests:
      curl -s http://127.0.0.1:8000/api/v1/health/rails | jq
    """
    return {"status": "ok", "app": settings.app_name, **rails_readiness()}


@router.get("/metrics")
async def metrics_snapshot():
    """Lightweight counters for ops dashboards (Prometheus export can wrap later)."""
    snap = metrics.snapshot()
    return {
        "app": settings.app_name,
        "environment": settings.environment,
        "version": settings.app_version,
        **snap,
    }
