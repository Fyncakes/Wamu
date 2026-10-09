"""Optional Sentry init — no-op when SENTRY_DSN is empty or SDK missing."""

from __future__ import annotations

import logging

logger = logging.getLogger(__name__)


def init_sentry(*, dsn: str | None, environment: str) -> bool:
    if not dsn:
        return False
    try:
        import sentry_sdk
        from sentry_sdk.integrations.fastapi import FastApiIntegration
        from sentry_sdk.integrations.starlette import StarletteIntegration
    except ImportError:
        logger.warning("SENTRY_DSN set but sentry-sdk not installed — skip")
        return False

    sentry_sdk.init(
        dsn=dsn,
        environment=environment,
        traces_sample_rate=0.05 if environment == "production" else 0.0,
        integrations=[
            StarletteIntegration(transaction_style="endpoint"),
            FastApiIntegration(transaction_style="endpoint"),
        ],
        send_default_pii=False,
    )
    logger.info("Sentry initialized (env=%s)", environment)
    return True
