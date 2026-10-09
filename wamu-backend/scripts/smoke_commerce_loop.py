#!/usr/bin/env python3
"""Live smoke: Master Plan commerce loop against a running API.

  Discover shops → create merchant → catalog → order → pay → claim → deliver → review → dispute

Usage:
  python -m scripts.smoke_commerce_loop --base http://127.0.0.1:8000
"""

from __future__ import annotations

import argparse
import sys
import uuid
from typing import Any

import httpx


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def ok(msg: str) -> None:
    print(f"OK  {msg}")


def auth(client: httpx.Client, phone: str) -> dict[str, str]:
    client.post("/api/v1/auth/request-otp", json={"phone": phone})
    r = client.post("/api/v1/auth/verify-otp", json={"phone": phone, "code": "123456"})
    if r.status_code != 200:
        fail(f"OTP verify {phone}: {r.status_code} {r.text}")
    token = r.json()["access_token"]
    # Ensure profile exists
    me = client.get("/api/v1/users/me", headers={"Authorization": f"Bearer {token}"})
    if me.status_code == 200:
        user = me.json()
        if not user.get("first_name"):
            client.patch(
                "/api/v1/users/me/profile",
                headers={"Authorization": f"Bearer {token}"},
                json={"first_name": phone[-4:], "last_name": "Smoke"},
            )
    return {"Authorization": f"Bearer {token}"}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:8000")
    args = parser.parse_args()
    base = args.base.rstrip("/")

    with httpx.Client(base_url=base, timeout=30.0) as client:
        health = client.get("/api/v1/health")
        if health.status_code != 200:
            fail(f"health {health.status_code}")
        ok("health")

        # Unique phones per run (+256 + 9 digits)
        n = uuid.uuid4().int % 10_000_000
        merchant_phone = f"+2567{n:08d}"[:13]
        customer_phone = f"+2568{n:08d}"[:13]
        rider_phone = f"+2569{n:08d}"[:13]
        # Force exact length 13
        merchant_phone = f"+2567{(n % 100000000):08d}"
        customer_phone = f"+2568{((n + 1) % 100000000):08d}"
        rider_phone = f"+2569{((n + 2) % 100000000):08d}"
        suffix = f"{n % 10000:04d}"

        m_headers = auth(client, merchant_phone)
        c_headers = auth(client, customer_phone)
        r_headers = auth(client, rider_phone)
        ok(f"auth merchant/customer/rider ({suffix})")

        cats = client.get("/api/v1/categories").json()
        if not cats:
            fail("no categories seeded")
        cat_id = cats[0]["id"]
        ok(f"categories={len(cats)}")

        # Nearby empty (or only prior smoke shops)
        nearby0 = client.get(
            "/api/v1/businesses",
            params={"lat": 0.3476, "lng": 32.5825, "radius_km": 20},
        )
        if nearby0.status_code != 200:
            fail(f"nearby list {nearby0.status_code} {nearby0.text}")
        ok(f"nearby before create={len(nearby0.json())}")

        create = client.post(
            "/api/v1/businesses",
            headers=m_headers,
            json={
                "name": f"Smoke Kitchen {suffix}",
                "description": "Phase0 smoke merchant",
                "category_id": cat_id,
                "phone": merchant_phone,
                "location": {
                    "address_line": "Ntinda Shopping Centre",
                    "city": "Kampala",
                    "latitude": 0.3476,
                    "longitude": 32.6305,
                },
            },
        )
        if create.status_code not in (200, 201):
            fail(f"create business {create.status_code} {create.text}")
        biz = create.json()
        biz_id = biz["id"]
        ok(f"business created id={biz_id} verification={biz.get('verification_status')}")

        nearby1 = client.get(
            "/api/v1/businesses",
            params={"lat": 0.3476, "lng": 32.6305, "radius_km": 8},
        ).json()
        if not any(b["id"] == biz_id for b in nearby1):
            fail("new business not returned by nearby query")
        ok("nearby discoverability")

        # Product
        prod = client.post(
            f"/api/v1/products/business/{biz_id}",
            headers=m_headers,
            json={
                "name": f"Smoke Tilapia {suffix}",
                "description": "Grilled",
                "price": "18000",
                "currency": "UGX",
                "stock_quantity": 20,
                "category_id": cat_id,
            },
        )
        if prod.status_code not in (200, 201):
            # try alternate path
            prod = client.post(
                "/api/v1/products",
                headers=m_headers,
                json={
                    "business_id": biz_id,
                    "name": f"Smoke Tilapia {suffix}",
                    "description": "Grilled",
                    "price": "18000",
                    "currency": "UGX",
                    "stock_quantity": 20,
                    "category_id": cat_id,
                },
            )
        if prod.status_code not in (200, 201):
            fail(f"create product {prod.status_code} {prod.text}")
        product_id = prod.json()["id"]
        ok(f"product {product_id}")

        order = client.post(
            "/api/v1/orders",
            headers=c_headers,
            json={
                "business_id": biz_id,
                "fulfillment": "DELIVERY",
                "delivery_address": "Nakawa Trading Centre",
                "items": [{"product_id": product_id, "quantity": 1}],
            },
        )
        if order.status_code not in (200, 201):
            fail(f"create order {order.status_code} {order.text}")
        order_id = order.json()["id"]
        ok(f"order {order_id} status={order.json().get('status')}")

        # Stock must remain at create — commit happens on payment SUCCESS.
        stock_before = client.get(f"/api/v1/products/{product_id}").json().get("stock_quantity")
        if stock_before != 20:
            fail(f"stock should stay 20 after unpaid create, got {stock_before}")
        ok(f"stock unchanged after create ({stock_before})")

        # Open merchant↔customer chat so ORDER_PAID carries conversation_id.
        convo = client.post(
            "/api/v1/chat/conversations",
            headers=c_headers,
            json={"business_id": biz_id},
        )
        conversation_id = None
        if convo.status_code in (200, 201):
            conversation_id = convo.json().get("id")
            ok(f"chat conversation {conversation_id}")
        else:
            print(f"WARN open chat: {convo.status_code} {convo.text}")

        # Enroll rider BEFORE pay; admin must approve before auto-assign can pick them.
        enroll = client.post(
            "/api/v1/riders/me",
            headers=r_headers,
            json={"display_name": f"Smoke Rider {suffix}", "vehicle_type": "BODA"},
        )
        if enroll.status_code not in (200, 201):
            fail(f"enroll {enroll.status_code} {enroll.text}")
        rider_id = enroll.json().get("id")
        if not rider_id:
            fail(f"enroll missing id: {enroll.text}")
        ok("rider enrolled (pending approval)")

        a_headers = auth(client, "+256700000001")
        approve = client.post(
            f"/api/v1/admin/riders/{rider_id}/approve",
            headers=a_headers,
            json={"note": "smoke approve"},
        )
        if approve.status_code != 200:
            fail(f"approve rider {approve.status_code} {approve.text}")
        ok("rider approved by admin")

        pay = client.post(
            "/api/v1/payments",
            headers=c_headers,
            json={
                "order_id": order_id,
                "provider": "MTN",
                "idempotency_key": str(uuid.uuid4()),
                "phone": customer_phone,
            },
        )
        if pay.status_code not in (200, 201):
            fail(f"pay {pay.status_code} {pay.text}")
        ok(f"payment status={pay.json().get('status')}")

        stock_after = client.get(f"/api/v1/products/{product_id}").json().get("stock_quantity")
        if stock_after != 19:
            fail(f"stock should be 19 after pay qty=1, got {stock_after}")
        ok(f"stock committed on pay ({stock_after})")

        payouts = client.get(f"/api/v1/businesses/{biz_id}/payouts", headers=m_headers)
        if payouts.status_code != 200:
            fail(f"payouts {payouts.status_code} {payouts.text}")
        rows = payouts.json()
        if not rows:
            fail("expected merchant payout after successful collection")
        if rows[0].get("status") not in ("SUCCESS", "PENDING", "PROCESSING"):
            fail(f"unexpected payout status {rows[0].get('status')}")
        ok(f"merchant payout status={rows[0].get('status')}")

        notes = client.get("/api/v1/notifications", headers=m_headers)
        if notes.status_code == 200:
            paid_notes = [n for n in notes.json() if n.get("type") == "ORDER_PAID"]
            if not paid_notes:
                fail("merchant missing ORDER_PAID notification")
            data = paid_notes[0].get("data") or {}
            if conversation_id and data.get("conversation_id") != conversation_id:
                fail(
                    f"ORDER_PAID conversation_id mismatch: "
                    f"{data.get('conversation_id')} != {conversation_id}"
                )
            ok("ORDER_PAID notify (+ conversation_id)" if conversation_id else "ORDER_PAID notify")

        if conversation_id:
            msgs = client.get(
                f"/api/v1/chat/conversations/{conversation_id}/messages",
                headers=c_headers,
            )
            if msgs.status_code == 200:
                systems = [
                    m
                    for m in msgs.json()
                    if (m.get("message_type") or "").upper() == "SYSTEM"
                    and "Rider" in (m.get("body") or "")
                ]
                if systems:
                    ok(f"chat SYSTEM rider line: {systems[-1].get('body')}")
                else:
                    print("WARN no rider SYSTEM message in chat yet")
            else:
                print(f"WARN list messages: {msgs.status_code}")
        else:
            print(f"WARN notifications: {notes.status_code}")

        mine = client.get("/api/v1/deliveries/mine", headers=r_headers).json()
        delivery_id = None
        if mine:
            delivery_id = mine[0]["id"]
            ok(f"auto-assigned delivery {delivery_id} status={mine[0].get('status')}")
        else:
            # Fallback: open pool + claim (no available rider at payment time)
            open_jobs = client.get("/api/v1/deliveries/open", headers=r_headers).json()
            if not open_jobs:
                # Last resort — delivery for this order from customer view
                by_order = client.get(
                    f"/api/v1/deliveries/by-order/{order_id}",
                    headers=c_headers,
                )
                if by_order.status_code != 200:
                    fail("no delivery created after payment")
                delivery_id = by_order.json()["id"]
                # If unassigned, claim; if assigned to us, continue; else fail clearly
                if by_order.json().get("rider_id") is None:
                    claim = client.post(
                        f"/api/v1/deliveries/{delivery_id}/claim",
                        headers=r_headers,
                    )
                    if claim.status_code != 200:
                        fail(f"claim {claim.status_code} {claim.text}")
                    ok(f"claimed delivery {delivery_id}")
                else:
                    fail(
                        "delivery assigned to another rider — run smoke on a fresh DB "
                        "or stop leftover riders"
                    )
            else:
                claim = client.post(
                    f"/api/v1/deliveries/{open_jobs[0]['id']}/claim",
                    headers=r_headers,
                )
                if claim.status_code != 200:
                    fail(f"claim {claim.status_code} {claim.text}")
                delivery_id = claim.json()["id"]
                ok(f"claimed delivery {delivery_id}")

        # Advance FSM to DELIVERED
        path = [
            "GOING_TO_PICKUP",
            "AT_PICKUP",
            "PICKED_UP",
            "IN_TRANSIT",
            "DELIVERED",
        ]
        for status in path:
            payload: dict[str, Any] = {"status": status}
            if status == "DELIVERED":
                payload["proof_note"] = "Handed to customer at gate"
            adv = client.patch(
                f"/api/v1/deliveries/{delivery_id}",
                headers=r_headers,
                json=payload,
            )
            if adv.status_code != 200:
                fail(f"advance → {status}: {adv.status_code} {adv.text}")
        ok("delivery advanced to DELIVERED (with PoD note)")

        order2 = client.get(f"/api/v1/orders/{order_id}", headers=c_headers).json()
        if order2.get("status") != "DELIVERED":
            fail(f"order not DELIVERED after delivery complete: {order2.get('status')}")
        ok("order status synced DELIVERED")

        # Customer PENDING cancel + merchant cancel of a PAID pickup order
        reject_order = client.post(
            "/api/v1/orders",
            headers=c_headers,
            json={
                "business_id": biz_id,
                "fulfillment": "PICKUP",
                "items": [{"product_id": product_id, "quantity": 1}],
            },
        )
        if reject_order.status_code not in (200, 201):
            fail(f"second order {reject_order.status_code} {reject_order.text}")
        rid = reject_order.json()["id"]
        cancel = client.patch(
            f"/api/v1/orders/{rid}/status",
            headers=c_headers,
            json={"status": "CANCELLED"},
        )
        if cancel.status_code == 200:
            ok("customer cancel PENDING works")
        else:
            print(f"WARN customer cancel: {cancel.status_code} {cancel.text}")

        paid_cancel = client.post(
            "/api/v1/orders",
            headers=c_headers,
            json={
                "business_id": biz_id,
                "fulfillment": "PICKUP",
                "items": [{"product_id": product_id, "quantity": 1}],
            },
        )
        if paid_cancel.status_code not in (200, 201):
            fail(f"paid-cancel order {paid_cancel.status_code} {paid_cancel.text}")
        pcid = paid_cancel.json()["id"]
        stock_before = client.get(f"/api/v1/products/{product_id}").json().get("stock_quantity")
        pay2 = client.post(
            "/api/v1/payments",
            headers=c_headers,
            json={
                "order_id": pcid,
                "provider": "AIRTEL",
                "idempotency_key": str(uuid.uuid4()),
                "phone": customer_phone,
            },
        )
        if pay2.status_code not in (200, 201):
            fail(f"pay2 {pay2.status_code} {pay2.text}")
        if pay2.json().get("status") != "SUCCESS":
            fail(f"pay2 status={pay2.json().get('status')}")
        ok("AIRTEL payment SUCCESS (labeled mock)")

        m_cancel = client.patch(
            f"/api/v1/orders/{pcid}/status",
            headers=m_headers,
            json={"status": "CANCELLED"},
        )
        if m_cancel.status_code != 200:
            fail(f"merchant cancel paid {m_cancel.status_code} {m_cancel.text}")
        stock_after_cancel = (
            client.get(f"/api/v1/products/{product_id}").json().get("stock_quantity")
        )
        if stock_before is not None and stock_after_cancel != stock_before:
            fail(
                f"stock not restored after merchant cancel: "
                f"before={stock_before} after={stock_after_cancel}"
            )
        ok("merchant cancel PAID restores stock + refunds")
        payouts_after = client.get(
            f"/api/v1/businesses/{biz_id}/payouts", headers=m_headers
        ).json()
        reversed_rows = [
            p
            for p in payouts_after
            if p.get("order_id") == pcid and p.get("status") == "REVERSED"
        ]
        if not reversed_rows:
            # Payout may still be SUCCESS if reverse missed — fail loudly
            matching = [p for p in payouts_after if p.get("order_id") == pcid]
            fail(f"expected REVERSED payout for cancelled order, got {matching}")
        ok("merchant payout REVERSED after cancel")

        review = client.post(
            "/api/v1/reviews",
            headers=c_headers,
            json={
                "business_id": biz_id,
                "order_id": order_id,
                "rating": 5,
                "comment": "Smoke test review",
                "rider_rating": 4,
            },
        )
        if review.status_code not in (200, 201):
            fail(f"review {review.status_code} {review.text}")
        body: dict[str, Any] = review.json()
        if body.get("rider_rating") != 4:
            fail(f"rider_rating missing in response: {body}")
        ok("business+rider review")

        dispute = client.post(
            "/api/v1/disputes",
            headers=c_headers,
            json={
                "order_id": order_id,
                "reason": "OTHER",
                "description": "Smoke dispute — please dismiss",
            },
        )
        if dispute.status_code != 201:
            fail(f"open dispute {dispute.status_code} {dispute.text}")
        mine_d = client.get("/api/v1/disputes/mine", headers=c_headers)
        if mine_d.status_code != 200 or not mine_d.json():
            fail(f"disputes/mine {mine_d.status_code} {mine_d.text}")
        ok(f"dispute opened status={dispute.json().get('status')}")
        dispute_id = dispute.json()["id"]

        # Admin ops: verify merchant + resolve dispute
        a_headers = auth(client, "+256700000001")
        verify = client.post(
            f"/api/v1/admin/businesses/{biz_id}/verify",
            headers=a_headers,
        )
        if verify.status_code != 200:
            fail(f"admin verify {verify.status_code} {verify.text}")
        if verify.json().get("verification_status") != "VERIFIED":
            fail(f"verify status={verify.json().get('verification_status')}")
        ok("admin verified business")

        m_notes = client.get("/api/v1/notifications", headers=m_headers)
        if m_notes.status_code == 200:
            verified_notes = [
                n for n in m_notes.json() if n.get("type") == "BUSINESS_VERIFIED"
            ]
            if verified_notes:
                ok("merchant BUSINESS_VERIFIED notify")
            else:
                print("WARN missing BUSINESS_VERIFIED notification")

        resolve = client.post(
            f"/api/v1/admin/disputes/{dispute_id}/resolve",
            headers=a_headers,
            json={"status": "RESOLVED_REJECT", "resolution_note": "Smoke dismiss"},
        )
        if resolve.status_code != 200:
            fail(f"admin resolve dispute {resolve.status_code} {resolve.text}")
        if resolve.json().get("status") != "RESOLVED_REJECT":
            fail(f"resolve status={resolve.json().get('status')}")
        ok("admin resolved dispute (REJECT)")

        rides = client.post(
            "/api/v1/rides",
            headers=c_headers,
            json={
                "pickup_address": "Ntinda market",
                "dropoff_address": "Nakawa trading",
            },
        )
        if rides.status_code != 201:
            fail(f"expected rides 201, got {rides.status_code} {rides.text}")
        ok(f"passenger ride status={rides.json().get('status')}")

    print("\nSMOKE PASS — commerce loop OK")


if __name__ == "__main__":
    main()
