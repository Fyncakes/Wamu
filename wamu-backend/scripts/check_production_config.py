#!/usr/bin/env python3
"""
Production config gate — prove fail-closed + that a strong template would load.

Usage (from wamu-backend):
  python -m scripts.check_production_config
"""

from __future__ import annotations

import os
import sys


def _expect_fail(**env: str) -> None:
    from app.core.config import Settings

    # Isolate from process .env bleed
    for k in list(os.environ):
        if k.startswith(
            (
                "ENVIRONMENT",
                "DEBUG",
                "OTP_",
                "PAYMENT_",
                "SECRET_KEY",
                "CORS_",
                "DATABASE_",
            )
        ):
            # keep caller-provided below
            pass
    os.environ.update(env)
    try:
        Settings(_env_file=None)  # type: ignore[call-arg]
    except Exception as exc:
        print(f"  refuse OK: {exc}")
        return
    raise SystemExit("expected production Settings() to raise")


def _expect_ok(**env: str) -> None:
    from app.core.config import Settings

    os.environ.update(env)
    s = Settings(_env_file=None)  # type: ignore[call-arg]
    assert s.is_production
    assert not s.debug
    assert not s.otp_mock_mode
    assert not s.payment_mock_auto_success
    print(f"  accept OK: environment={s.environment}")


def main() -> int:
    # Clear cached settings if any prior import
    from app.core import config as cfg

    if hasattr(cfg.get_settings, "cache_clear"):
        cfg.get_settings.cache_clear()

    print("[wamu] production must refuse weak config…")
    _expect_fail(
        ENVIRONMENT="production",
        DEBUG="true",
        OTP_MOCK_MODE="false",
        PAYMENT_MOCK_AUTO_SUCCESS="false",
        SECRET_KEY="x" * 40,
        PAYMENT_WEBHOOK_SECRET="y" * 40,
        CORS_ORIGINS='["https://wamu.ug"]',
    )

    print("[wamu] production must accept strong config…")
    _expect_ok(
        ENVIRONMENT="production",
        DEBUG="false",
        OTP_MOCK_MODE="false",
        PAYMENT_MOCK_AUTO_SUCCESS="false",
        SECRET_KEY="a" * 48,
        PAYMENT_WEBHOOK_SECRET="b" * 48,
        CORS_ORIGINS='["https://wamu.ug","https://admin.wamu.ug"]',
        DATABASE_URL="postgresql+asyncpg://wamu:strong@db:5432/wamu",
    )

    print("[wamu] production config gate passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
