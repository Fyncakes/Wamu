# WAMU — Uganda Social-Economic Network

**Connect · Discover local businesses · Transact · Deliver**

Monorepo for WAMU: Flutter + FastAPI + PostgreSQL. Execution follows the
**Unified Master Project Plan v3** — transaction-first commerce MVP, with
social/discovery/mobility layers added after the loop is proven.

See [`documentation/MASTER_PLAN_V3_ALIGNMENT.md`](documentation/MASTER_PLAN_V3_ALIGNMENT.md).

## Product loop (MVP)

```
Nearby shops → Merchant chat → Order → MoMo pay → Delivery → Review
```

Primary app shell: **Shops | Chats | Orders | You**.

## Repository layout

| Path | Purpose |
|------|---------|
| [`wamu-backend/`](wamu-backend/) | FastAPI + PostgreSQL API |
| [`wamu-mobile/`](wamu-mobile/) | Flutter app (Android-first) |
| [`wamu-admin/`](wamu-admin/) | Next.js admin dashboard |
| [`infrastructure/`](infrastructure/) | Docker Compose stack |
| [`documentation/`](documentation/) | Architecture & runbooks |

## Run locally (dev)

```bash
# API
cd wamu-backend && source .venv/bin/activate && ./scripts/run_local.sh

# Admin
cd wamu-admin && npm install && cp .env.local.example .env.local && npm run dev

# Mobile
export PATH="$HOME/flutter/bin:$PATH"
cd wamu-mobile && flutter pub get && flutter run
```

Mock OTP (local only): **`123456`** · Admin phone: `+256700000001`

## Staging stack

```bash
cp infrastructure/.env.staging.example infrastructure/.env.staging
# Replace every CHANGE_ME value, then:
./infrastructure/staging_up.sh
cd wamu-backend && python -m scripts.staging_readiness --url http://127.0.0.1:8000
```

## Explicitly deferred (Master Plan)

Short-video Discover home, passenger rides (Wamu Move), general social/communities as primary,
nationwide day-one delivery, ML recommendations, microservices/Kubernetes without need.
