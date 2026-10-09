#!/usr/bin/env python3
"""
Print payment / push / WebRTC rail readiness (no secrets).

Usage (from wamu-backend, with .env or env vars loaded):
  python -m scripts.staging_readiness
  # or against a running API:
  python -m scripts.staging_readiness --url http://127.0.0.1:8000
"""

from __future__ import annotations

import argparse
import json
import sys


def _local() -> dict:
    from app.services.staging_readiness import rails_readiness

    return rails_readiness()


def _remote(url: str) -> dict:
    import urllib.request

    base = url.rstrip("/")
    if not base.endswith("/api/v1"):
        # allow http://host:8000 or full /api/v1
        if "/api/v1" not in base:
            base = f"{base}/api/v1"
    req = urllib.request.Request(f"{base}/health/rails", method="GET")
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read().decode())


def main() -> int:
    parser = argparse.ArgumentParser(description="Wamu staging rails readiness")
    parser.add_argument(
        "--url",
        help="API base (e.g. http://127.0.0.1:8000) — uses GET /health/rails",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit 1 if ready_for_mock_dry_run is false",
    )
    parser.add_argument(
        "--strict-live",
        action="store_true",
        help="Exit 1 unless live OTP + MoMo sandbox + FCM are ready (private-beta gate)",
    )
    args = parser.parse_args()
    data = _remote(args.url) if args.url else _local()
    print(json.dumps(data, indent=2, sort_keys=True))

    ok_mock = data.get("ready_for_mock_dry_run")
    momo = data.get("ready_for_momo_sandbox")
    otp = data.get("ready_for_live_otp")
    fcm = data.get("fcm_server_key_set")
    calls = data.get("ready_for_carrier_calls")
    print(file=sys.stderr)
    print(f"mock dry-run:     {'OK' if ok_mock else 'NO'}", file=sys.stderr)
    print(f"live OTP (AT):    {'OK' if otp else 'OTP_MOCK_MODE=false + AFRICASTALKING_*'}", file=sys.stderr)
    print(f"MoMo sandbox:     {'OK' if momo else 'fill MTN_* + PAYMENT_MOCK_AUTO_SUCCESS=false'}", file=sys.stderr)
    print(f"FCM server key:   {'OK' if fcm else 'set FCM_SERVER_KEY'}", file=sys.stderr)
    print(
        f"carrier TURN:     {'OK' if calls else 'print_turn_env + --profile turn (non-loopback IP)'}",
        file=sys.stderr,
    )
    if args.strict and not ok_mock:
        return 1
    if args.strict_live and not (otp and momo and fcm):
        print(
            "\n[--strict-live] private beta incomplete — live OTP, MoMo, and FCM required",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
