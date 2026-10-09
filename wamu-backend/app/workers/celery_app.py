"""Celery app — notifications, payment reconciliation (async off the request path)."""

from celery import Celery
from celery.schedules import crontab

from app.core.config import get_settings

settings = get_settings()

celery_app = Celery("wamu", broker=settings.celery_broker_url, include=["app.workers.tasks"])
celery_app.conf.task_always_eager = settings.environment == "test"
celery_app.conf.task_serializer = "json"
celery_app.conf.result_serializer = "json"
celery_app.conf.accept_content = ["json"]
celery_app.conf.timezone = "Africa/Kampala"
celery_app.conf.enable_utc = True

# Reconcile open MoMo payments every 5 minutes
celery_app.conf.beat_schedule = {
    "reconcile-payments-every-5-minutes": {
        "task": "wamu.reconcile_payments",
        "schedule": 300.0,
        "args": (),
        "kwargs": {"stale_hours": 24, "limit": 100},
    },
    "reconcile-payouts-every-5-minutes": {
        "task": "wamu.reconcile_payouts",
        "schedule": 300.0,
        "kwargs": {"stale_hours": 24, "limit": 100},
    },
    # Nightly catch-up (Kampala 02:15)
    "reconcile-payments-nightly": {
        "task": "wamu.reconcile_payments",
        "schedule": crontab(hour=2, minute=15),
        "kwargs": {"stale_hours": 24, "limit": 500},
    },
    "reconcile-payouts-nightly": {
        "task": "wamu.reconcile_payouts",
        "schedule": crontab(hour=2, minute=30),
        "kwargs": {"stale_hours": 24, "limit": 500},
    },
    # Short-video lifecycle: Active → Archived → Permanently deleted (age-based).
    "video-lifecycle-nightly": {
        "task": "wamu.video_lifecycle",
        "schedule": crontab(hour=3, minute=0),
        "kwargs": {},
    },
}
