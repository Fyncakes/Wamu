"""Payment reconciliation — poll providers for PENDING/PROCESSING; expire stale rows."""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.metrics import PAYMENT_FAILED, metrics
from app.integrations.payments.provider import get_payment_provider
from app.models.audit import AuditLog
from app.models.payment import Payment, PaymentStatus

logger = logging.getLogger(__name__)


async def reconcile_pending_payments(
    db: AsyncSession,
    *,
    stale_hours: int = 24,
    limit: int = 50,
) -> dict:
    """
    For open payments:
    1) Ask provider check_status when a reference exists
    2) Mark SUCCESS/FAILED accordingly (SUCCESS remains immutable elsewhere)
    3) Fail stale PENDING/PROCESSING older than stale_hours
    """
    open_statuses = {PaymentStatus.PENDING.value, PaymentStatus.PROCESSING.value}
    result = await db.execute(
        select(Payment)
        .where(Payment.status.in_(open_statuses))
        .order_by(Payment.created_at.asc())
        .limit(limit)
    )
    payments = list(result.scalars().all())
    checked = 0
    updated = 0
    expired = 0
    errors = 0
    now = datetime.now(timezone.utc)
    cutoff = now - timedelta(hours=stale_hours)

    for payment in payments:
        checked += 1
        try:
            if payment.provider_reference:
                provider = get_payment_provider(payment.provider)
                status_result = await provider.check_status(payment.provider_reference)
                new_status = (status_result.status or "").upper()
                payment.raw_response = {
                    **(payment.raw_response or {}),
                    "reconcile": status_result.raw,
                    "reconciled_at": now.isoformat(),
                }
                if new_status == "SUCCESS" and payment.status != PaymentStatus.SUCCESS.value:
                    payment.status = PaymentStatus.SUCCESS.value
                    from app.services.payment import finalize_payment_success

                    await finalize_payment_success(
                        db,
                        payment,
                        audit_action="PAYMENT_RECONCILED_SUCCESS",
                    )
                    updated += 1
                elif new_status == "FAILED" and payment.status != PaymentStatus.FAILED.value:
                    payment.status = PaymentStatus.FAILED.value
                    metrics.incr(PAYMENT_FAILED)
                    updated += 1
                elif new_status == "PROCESSING":
                    payment.status = PaymentStatus.PROCESSING.value

            created = payment.created_at
            if created is not None and created.tzinfo is None:
                created = created.replace(tzinfo=timezone.utc)
            if (
                payment.status in open_statuses
                and created is not None
                and created < cutoff
            ):
                payment.status = PaymentStatus.FAILED.value
                payment.raw_response = {
                    **(payment.raw_response or {}),
                    "reconcile_expired": True,
                    "expired_at": now.isoformat(),
                }
                metrics.incr(PAYMENT_FAILED)
                db.add(
                    AuditLog(
                        actor_id=payment.user_id,
                        action="PAYMENT_RECONCILE_EXPIRED",
                        entity_type="payment",
                        entity_id=payment.id,
                        metadata_json={"stale_hours": stale_hours},
                    )
                )
                expired += 1
                updated += 1
        except Exception:
            logger.exception("Reconcile failed payment_id=%s", payment.id)
            errors += 1

    await db.flush()
    summary = {
        "checked": checked,
        "updated": updated,
        "expired": expired,
        "errors": errors,
    }
    logger.info("Payment reconcile %s", summary)
    return summary
