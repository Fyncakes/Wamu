#!/usr/bin/env python3
"""
MOCK collection → merchant payout dry-run against a live API.

Does not need MoMo sandbox keys. Use this to verify the money path before
filling MTN_* / AIRTEL_* in infrastructure/.env.staging.

Prereqs:
  - API running (uvicorn or staging compose)
  - OTP mock mode (default in development)
  - A seeded business with a product (scripts/bootstrap.py) OR pass IDs

Usage:
  python -m scripts.payments_dry_run --base http://127.0.0.1:8000
  python -m scripts.payments_dry_run --base http://127.0.0.1:8000 \\
      --business-id <uuid> --product-id <uuid>
"""

from __future__ import annotations

import argparse
import json
import sys
import uuid
from typing import Any

import httpx


def _otp_login(client: httpx.Client, phone: str, code: str = "123456") -> str:
    # Ensure challenge exists (mock OTP)
    client.post("/api/v1/auth/request-otp", json={"phone": phone})
    r = client.post(
        "/api/v1/auth/verify-otp",
        json={"phone": phone, "code": code},
    )
    r.raise_for_status()
    return r.json()["access_token"]


def _pick_catalog(client: httpx.Client, headers: dict[str, str]) -> tuple[str, str]:
    """Best-effort: first product from discover / businesses list."""
    # Try businesses then products
    biz = client.get("/api/v1/businesses", headers=headers)
    if biz.status_code == 200:
        items = biz.json()
        if isinstance(items, dict):
            items = items.get("items") or items.get("results") or []
        if items:
            bid = str(items[0]["id"])
            prods = client.get(f"/api/v1/products?business_id={bid}", headers=headers)
            if prods.status_code == 200:
                plist = prods.json()
                if isinstance(plist, dict):
                    plist = plist.get("items") or plist.get("results") or []
                if plist:
                    return bid, str(plist[0]["id"])
    raise SystemExit(
        "No catalog found — run scripts/bootstrap.py or pass --business-id / --product-id"
    )


def run(base: str, business_id: str | None, product_id: str | None, phone: str) -> dict[str, Any]:
    with httpx.Client(base_url=base.rstrip("/"), timeout=30.0) as client:
        rails = client.get("/api/v1/health/rails")
        rails.raise_for_status()
        rails_body = rails.json()
        if not rails_body.get("ready_for_mock_dry_run", True):
            raise SystemExit(f"API not ready for mock dry-run: {rails_body}")

        token = _otp_login(client, phone)
        headers = {"Authorization": f"Bearer {token}"}

        if not business_id or not product_id:
            business_id, product_id = _pick_catalog(client, headers)

        order = client.post(
            "/api/v1/orders",
            headers=headers,
            json={
                "business_id": business_id,
                "items": [{"product_id": product_id, "quantity": 1}],
                "fulfillment": "PICKUP",
            },
        )
        order.raise_for_status()
        order_id = order.json()["id"]

        pay = client.post(
            "/api/v1/payments",
            headers=headers,
            json={
                "order_id": order_id,
                "provider": "MOCK",
                "phone": phone,
                "idempotency_key": f"cli-dry-{uuid.uuid4().hex}",
            },
        )
        pay.raise_for_status()
        payment = pay.json()

        detail = client.get(f"/api/v1/orders/{order_id}", headers=headers)
        detail.raise_for_status()
        order_body = detail.json()

        return {
            "rails": {
                k: rails_body.get(k)
                for k in (
                    "ready_for_mock_dry_run",
                    "ready_for_momo_sandbox",
                    "ready_for_carrier_calls",
                    "mtn_collections_configured",
                    "payment_mock_auto_success",
                )
            },
            "order_id": order_id,
            "payment_status": payment.get("status"),
            "payment_provider": payment.get("provider"),
            "order_payment_status": order_body.get("payment_status"),
            "order_status": order_body.get("status"),
            "next": (
                "Fill MTN_* in infrastructure/.env.staging, set "
                "PAYMENT_MOCK_AUTO_SUCCESS=false, restart staging, then "
                "repeat with provider=MTN against sandbox."
                if not rails_body.get("ready_for_momo_sandbox")
                else "MoMo sandbox flags look set — try provider=MTN with a sandbox phone."
            ),
        }


def main() -> int:
    p = argparse.ArgumentParser(description="Wamu MOCK payments dry-run")
    p.add_argument("--base", default="http://127.0.0.1:8000")
    p.add_argument("--phone", default="+256700000088")
    p.add_argument("--business-id")
    p.add_argument("--product-id")
    args = p.parse_args()
    try:
        result = run(args.base, args.business_id, args.product_id, args.phone)
    except httpx.HTTPError as exc:
        print(f"HTTP error: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    if result.get("payment_status") != "SUCCESS":
        print("Expected payment SUCCESS (enable PAYMENT_MOCK_AUTO_SUCCESS for MOCK).", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
