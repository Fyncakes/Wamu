# WAMU Phase 0 — Stabilization (Development-Ready)

**Rule:** Fix → Secure → Test → Harden → then grow.  
**Source brief:** Senior developer build summary (Chat → Discover → Buy → Pay flywheel).

This phase does **not** add product features. It makes the existing Flutter + FastAPI + Postgres stack safe to develop against.

---

## Audit verdict (honest)

| Area | Score | Note |
|------|-------|------|
| Concept / Uganda positioning | Strong | Keep messaging-first + commerce plug-in |
| Engineering foundation | Solid | Don't rewrite Flutter/FastAPI/Postgres |
| Production readiness | Not ready | Was ~4.5/10 — Phase 0 raises the floor |

**Already good (keep):** server-side order totals, payment idempotency columns, order FSM, JWT + hashed refresh/OTP, Redis rate-limit + Celery, health endpoints.

---

## Tickets (prioritized)

| ID | Sev | Status | Item |
|----|-----|--------|------|
| **WAMU-001** | P0 | ✅ Done | Production fail-closed config (`ENVIRONMENT=production` refuses DEBUG/mocks/CORS `*`/weak secrets). Templates: `.env.example`, `.env.production.example` |
| **WAMU-002** | P0 | ✅ Done | Payment webhook HMAC (`X-Wamu-Signature`). Unsigned rejected when mocks off / production |
| **WAMU-003** | P0 | ✅ Done | Mock payments gated by env; production forbids `PAYMENT_MOCK_AUTO_SUCCESS` |
| **WAMU-004** | P0 | ✅ Done | Chat WS membership check before accept |
| **WAMU-005** | P0 | ✅ Done | Short-lived WS tickets (`POST /chat/ws-ticket`, `/calls/ws-ticket`); Flutter uses tickets; access JWT in query disabled in production |
| **WAMU-006** | P1 | ✅ Done (v1) | Redis Pub/Sub fan-out for chat (`app/core/realtime.py`); local fallback if Redis down |
| **WAMU-007** | P1 | Partial | OTP mock still OK in development; production forbids. Strip any OTP from API bodies in SMS provider path when wired |
| **WAMU-008** | P1 | ✅ Done | CORS default no longer `*`; production forbids wildcard |
| **WAMU-009** | P1 | ✅ Done | GitHub Actions CI: backend pytest + Flutter analyze/test |
| **WAMU-010** | P1 | ✅ Done (v1) | Incremental Alembic chain: `0001_initial` baseline + `0002_phase0_integrity` indexes; `scripts/migrate.py` for deploys |
| **WAMU-011** | P1 | ✅ Done | Payment idempotency + WS ticket membership tests (`test_phase0_commerce_ws.py`) |
| **WAMU-012** | P2 | ✅ Done (v1) | `X-Request-ID` + `/api/v1/metrics` counters; optional `SENTRY_DSN` |
| **WAMU-013** | P2 | Partial | Inbox filter chip widget test; broader Flutter integration later |
| **WAMU-014** | P1 | ✅ Done | Offline outbox + thread cache behind `KvStore` (encrypted Drift/sqlite3mc native / secure storage web) |

---

## How to develop locally (safe)

```bash
# Backend
cd wamu-backend
cp .env.example .env   # already development-safe
source .venv/bin/activate
pytest -q
uvicorn app.main:app --reload --host 127.0.0.1 --port 8000

# Mobile
cd wamu-mobile
flutter pub get
flutter test
flutter run -d chrome --web-browser-flag "--disable-web-security"
```

**Production dry-run (should refuse weak config):**
```bash
ENVIRONMENT=production DEBUG=false OTP_MOCK_MODE=false \
PAYMENT_MOCK_AUTO_SUCCESS=false \
SECRET_KEY=$(openssl rand -hex 32) \
PAYMENT_WEBHOOK_SECRET=$(openssl rand -hex 32) \
CORS_ORIGINS='["https://wamu.ug"]' \
python -c "from app.core.config import Settings; print(Settings())"
```

---

## Advice (what NOT to do next)

1. **Do not** start Mini Apps, wallet, rides, or E2EE until tickets **WAMU-010–012** and a real MTN/Airtel staging webhook path exist.
2. **Do not** become a money custodian — keep licensed providers; BoU/AML later.
3. **Do** treat Redis Pub/Sub as enough until multi-region volume forces a Go/Centrifugo gateway.
4. **Do** keep the flywheel: messaging quality → discover → order → verified payment → review.

---

## Payment rails (done this sprint)

| Item | Status |
|------|--------|
| Signed MTN/Airtel webhooks | ✅ |
| Provider adapters + `check_status` poll | ✅ |
| Celery reconcile (5m + nightly) + admin trigger | ✅ |
| Staging compose secrets template + worker/beat | ✅ (`infrastructure/.env.staging.example`) |
| Staging deploy gate | ✅ `staging_up.sh`, API healthcheck, `.dockerignore`, `documentation/DEPLOY.md` |
| Alembic greenfield | ✅ Idempotent `0003`–`0007` after `0001` create_all |
| Merchant payout (non-custodial disbursement) | ✅ (`MerchantPayout` + MoMo disbursement adapters) |
| Platform fee (`PLATFORM_FEE_BPS`) | ✅ Net payout; fee stays in MoMo float (default 0) |
| Admin fee / GMV report | ✅ `GET /admin/stats` + Payouts page |

## Deploy now

```bash
# once: join docker group so compose works without sudo
sudo usermod -aG docker "$USER"   # then log out/in

./infrastructure/staging_up.sh
./infrastructure/verify_deploy.sh
./infrastructure/staging_down.sh   # when done
```

Full runbook: **`documentation/DEPLOY.md`**.

Without Docker: `./wamu-backend/scripts/run_local.sh` then `./infrastructure/verify_deploy.sh` → expect smoke **passed**.  
Production gate: `cd wamu-backend && python -m scripts.check_production_config`.

## After staging is up (optional carriers)

See **[MVP_V1_PRIVATE_BETA.md](MVP_V1_PRIVATE_BETA.md)** for the A–I private-beta checklist (SMS OTP, MoMo, FCM, trust, checkout, status/community).

1. Fill `MTN_*` / `AIRTEL_*` + `AFRICASTALKING_*` in `.env.staging`; set mocks off when ready  
2. Live TURN call on LAN/public IP (`documentation/WEBRTC_TURN.md`)  
3. `flutterfire configure` + `FCM_SERVER_KEY` for real push  
4. Signal-protocol E2EE / Mini Apps / wallet / rides — **only after** private beta is boringly reliable  

See also: `documentation/DEPLOY.md`, `documentation/MVP_V1_PRIVATE_BETA.md`, `documentation/WHATSAPP_PARITY_PLAN.md`, `documentation/PAYMENTS_STAGING.md`, `documentation/WEBRTC_TURN.md`, `documentation/PRESENCE_REDIS.md`, `documentation/PUSH_NOTIFICATIONS.md`

**One rule:** A reliable 10-feature Wamu beats an unreliable 100-feature super-app.
