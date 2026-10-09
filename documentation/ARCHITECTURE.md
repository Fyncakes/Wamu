# WAMU Architecture Notes

## Core flow (Master Plan v3 MVP)

```
Register (OTP) → Shops (nearby) → Business → Product → Chat / Cart → Order → Pay → Deliver → Review
```

Primary shell: **Shops | Chats | Orders | You**.
Short-video Discover and passenger rides are later phases.

## Money rules

1. Store all money as `NUMERIC(14,2)` — never float.
2. Currency locked to `UGX` in MVP.
3. Order `total = subtotal + delivery_fee` enforced in DB + service.
4. Order line items snapshot product name/price at purchase time.
5. Payments are idempotent (`user_id + idempotency_key`) and immutable after SUCCESS.

## Auth

Phone `+256[0-9]{9}` → OTP (hashed at rest) → short-lived JWT access + hashed refresh session.

## Chat

REST for history; WebSocket at `/api/v1/chat/ws/{conversation_id}?token=...` for realtime.
Scale path: Redis pub/sub fan-out.

## AI Level 1

Natural-language query → keyword/location parse → **only** returns rows from WAMU Postgres.
Never invent businesses or prices.

## Production checklist (Part 2A)

See `specs/` PDFs and backend README. Before real MoMo: wire MTN/Airtel adapters, webhook signatures, managed Postgres HA, backups, and secret management.
