"""Background tasks. Keep request handlers fast — push side effects here."""

from __future__ import annotations

import asyncio
import logging

from app.workers.celery_app import celery_app

logger = logging.getLogger(__name__)


@celery_app.task(name="wamu.send_push_notification")
def send_push_notification(
    user_id: str,
    title: str,
    body: str,
    data: dict | None = None,
) -> dict:
    """
    Deliver a data-oriented push to all registered devices for user_id.

    Callers must pass a generic title/body (e.g. "Wamu" / "New message") —
    never the chat transcript. Real message text stays for the authenticated
    in-app Notification inbox only.
    """

    async def _run() -> dict:
        from sqlalchemy import select

        from app.core.database import AsyncSessionLocal
        from app.integrations.push import assert_no_plaintext_leak, get_push_provider
        from app.models.device import DevicePushToken

        safe_data = {str(k): str(v) for k, v in (data or {}).items()}
        assert_no_plaintext_leak(safe_data, body)

        async with AsyncSessionLocal() as db:
            result = await db.execute(
                select(DevicePushToken).where(DevicePushToken.user_id == user_id)
            )
            tokens = list(result.scalars().all())

        if not tokens:
            logger.info("PUSH skip — no tokens user=%s", user_id)
            return {"status": "no_tokens", "user_id": user_id, "sent": 0}

        provider = get_push_provider()
        results = []
        for row in tokens:
            try:
                results.append(
                    await provider.send(
                        token=row.token,
                        title=title,
                        body=body,
                        data=safe_data,
                    )
                )
            except Exception as exc:
                logger.exception("PUSH send failed user=%s", user_id)
                results.append({"status": "error", "detail": str(exc)})
        return {
            "status": "ok",
            "user_id": user_id,
            "sent": len(results),
            "results": results,
        }

    try:
        return asyncio.run(_run())
    except Exception as exc:
        logger.exception("send_push_notification task failed")
        return {"status": "error", "detail": str(exc)}


@celery_app.task(name="wamu.reconcile_payments")
def reconcile_payments(stale_hours: int = 24, limit: int = 50) -> dict:
    """Poll open payments / expire stale ones. Scheduled via Celery Beat."""

    async def _run() -> dict:
        from app.core.database import AsyncSessionLocal
        from app.services.reconciliation import reconcile_pending_payments

        async with AsyncSessionLocal() as db:
            summary = await reconcile_pending_payments(
                db, stale_hours=stale_hours, limit=limit
            )
            await db.commit()
            return summary

    try:
        return asyncio.run(_run())
    except Exception as exc:
        logger.exception("reconcile_payments task failed")
        return {"status": "error", "detail": str(exc)}


@celery_app.task(name="wamu.reconcile_payouts")
def reconcile_payouts(stale_hours: int = 24, limit: int = 50) -> dict:
    """Poll open merchant disbursements / expire stale ones."""

    async def _run() -> dict:
        from app.core.database import AsyncSessionLocal
        from app.services.payout import reconcile_pending_payouts

        async with AsyncSessionLocal() as db:
            summary = await reconcile_pending_payouts(
                db, stale_hours=stale_hours, limit=limit
            )
            await db.commit()
            return summary

    try:
        return asyncio.run(_run())
    except Exception as exc:
        logger.exception("reconcile_payouts task failed")
        return {"status": "error", "detail": str(exc)}


@celery_app.task(name="wamu.video_lifecycle")
def video_lifecycle() -> dict:
    """Age-based Active → Archived → Permanently deleted (never engagement-based)."""

    async def _run() -> dict:
        from app.core.database import AsyncSessionLocal
        from app.services.discover import run_video_lifecycle

        async with AsyncSessionLocal() as db:
            summary = await run_video_lifecycle(db)
            await db.commit()
            return summary

    try:
        return asyncio.run(_run())
    except Exception as exc:
        logger.exception("video_lifecycle task failed")
        return {"status": "error", "detail": str(exc)}
