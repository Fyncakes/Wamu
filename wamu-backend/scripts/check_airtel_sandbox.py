#!/usr/bin/env python3
"""Validate Airtel Money UAT credentials (token + encryption key).

Portal: https://developers.airtel.africa → Uganda
  1. Create app, add Collection-APIs + Disbursement-APIs
  2. Request approval (TEST needs Partially Approved)
  3. Whitelist server IP under Settings → Security
  4. Set Disbursement PIN; copy client_id / client_secret into .env

Usage (from wamu-backend):
  python scripts/check_airtel_sandbox.py
  python scripts/check_airtel_sandbox.py --collect 752604392 --amount 500
  python scripts/check_airtel_sandbox.py --disburse 752604392 --amount 500

Requires AIRTEL_CLIENT_ID + AIRTEL_CLIENT_SECRET in .env (or environment).
Disburse also needs AIRTEL_DISBURSEMENT_PIN.
"""
from __future__ import annotations

import argparse
import asyncio
import os
import sys
from decimal import Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

# Load .env into process before Settings caches
_env = ROOT / ".env"
if _env.exists():
    for line in _env.read_text().splitlines():
        if not line or line.lstrip().startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


async def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--collect", metavar="MSISDN", help="USSD-push collection smoke")
    parser.add_argument("--disburse", metavar="MSISDN", help="B2C disbursement smoke")
    parser.add_argument("--amount", type=int, default=500)
    args = parser.parse_args()

    from app.core.config import get_settings
    from app.integrations.payments import airtel_common as ac
    from app.integrations.payments.disbursement import AirtelDisbursementAdapter
    from app.integrations.payments.provider import AirtelAdapter
    import httpx

    get_settings.cache_clear()
    s = get_settings()
    print(f"base_url={s.airtel_base_url}")
    print(f"client_id_set={bool(s.airtel_client_id)} secret_set={bool(s.airtel_client_secret)}")
    print(f"pin_set={bool(s.airtel_disbursement_pin)} sign={s.airtel_sign_collections}")

    if not ac.airtel_configured(s):
        print("FAIL: set AIRTEL_CLIENT_ID and AIRTEL_CLIENT_SECRET")
        return 1

    async with httpx.AsyncClient(timeout=25.0) as client:
        access, err = await ac.fetch_access_token(client, s)
        if not access:
            print("FAIL token:", err)
            return 1
        print("OK  OAuth token")
        pub, kerr = await ac.fetch_encryption_key(client, s, access)
        if not pub:
            print("WARN encryption key:", kerr)
            print("     (collections may fall back to unsigned v1; disbursement needs the key)")
        else:
            print(f"OK  encryption key ({len(pub)} chars)")

    if args.collect:
        r = await AirtelAdapter().initiate_payment(
            amount=Decimal(args.amount),
            currency=s.airtel_currency or "UGX",
            reference="airtel-check",
            phone=args.collect if args.collect.startswith("+") else f"+256{args.collect.lstrip('0')}",
        )
        print(f"collect status={r.status} ref={r.provider_reference}")
        print("  raw:", str(r.raw)[:500])
        if r.status == "FAILED":
            return 1

    if args.disburse:
        r = await AirtelDisbursementAdapter().initiate_disbursement(
            amount=Decimal(args.amount),
            currency=s.airtel_currency or "UGX",
            reference="airtel-check-out",
            payee_phone=args.disburse
            if args.disburse.startswith("+")
            else f"+256{args.disburse.lstrip('0')}",
        )
        print(f"disburse status={r.status} ref={r.provider_reference}")
        print("  raw:", str(r.raw)[:500])
        if r.status == "FAILED":
            return 1

    print("OK  Airtel sandbox check complete")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
