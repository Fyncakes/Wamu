# Current State Assessment — Financial Systems

**Date:** 2026-10-16  
**Brief:** Financial Ledger v2.0 — Deliverable 0 (complete before/with Phase A)

## Section 1 — Codebase answers

| Question | Answer |
|---|---|
| Ledger? | **No** prior double-entry ledger. Money lived as status/amount fields on `Payment`, `MerchantPayout`, and `Order`. Phase A adds `ledger_entries`. |
| MTN MoMo **collection**? | Yes — custom `httpx` `MTNAdapter` in `wamu-backend/app/integrations/payments/provider.py`. Mock when `PAYMENT_MOCK_AUTO_SUCCESS=true`. |
| MTN MoMo **disbursement**? | Ready in code — `MTNDisbursementAdapter` + queue/execute + ledger settle. Live money blocked only on provider credentials / onboarding. |
| Commission rules? | `PLATFORM_FEE_BPS` via `compute_platform_fee()` (was default 0). Phase A locks **250 bps (2.5%)** on order subtotal (excl. delivery). |
| Admin panel? | Next.js app in `wamu-admin/` + FastAPI `/admin/*` (`get_current_admin`). |
| Orders / multi-merchant? | One `Order` per shop; multi-shop checkout shares `checkout_batch_id`. Each order has its own payment. Delivery fee on first shop only. |
| Merchant payout destination? | `Business.payout_phone` + `payout_provider` (MTN / AIRTEL / MOCK). |
| Auth / RBAC? | User roles: CUSTOMER, BUSINESS, RIDER, ADMIN. Business member roles: OWNER, MANAGER, STAFF. |
| Deployment? | Docker Compose (local/staging), `start_wamu.sh` + Cloudflare quick tunnels for demos. |
| Testing? | pytest + GitHub Actions CI. No historical coverage gate; Phase A targets ≥90% on `commission` + `ledger` modules. |

## Locked business rules (Phase A)

| Rule | Value |
|---|---|
| Commission base | Order **subtotal** (excl. delivery) |
| Commission rate | **2.5%** (`PLATFORM_FEE_BPS=250`) |
| Provider fees | **Absorbed by Wamu**; Phase A records **estimated** `PROVIDER_FEE_BPS=150` (1.5% of customer total) |
| Delivery fee | 0% commission — credited to `rider_payable` |
| Multi-merchant | Per paid order (already split); not a parent-order allocation |
| Refunds | New reversing ledger groups only (immutable history) |
| Live payouts | **Out of scope** for Phase A |

## Key env flags

```
PLATFORM_FEE_BPS=250
PROVIDER_FEE_BPS=150
PAYOUT_AUTO_EXECUTE=true|false   # Phase B: false = queue PENDING only
SUSPENSE_ALERT_THRESHOLD_MINOR=100000
PAYMENT_MOCK_AUTO_SUCCESS=true|false
PAYMENT_MOMO_OTP_ENABLED=true|false
MTN_* / AIRTEL_*          # live rails when mock off
PAYMENT_WEBHOOK_SECRET
```

## Phase boundaries

- **Phase A (done):** ledger + commission accounting + merchant/admin read APIs + reports.
- **Phase B (done):** synthetic statement match, suspense + admin resolve, payout queue when `PAYOUT_AUTO_EXECUTE=false`, failed-payout notifications, daily Celery job.
- **Phase C (code done):** admin Execute queue, ledger settlement, dedicated disbursement keys, callbacks, `/health/rails.ready_for_live_disbursement`, rider fee payouts, owner commission withdraw, collection refund adapters. Waiting only on MTN/Airtel credentials — see `PHASE_C_GO_LIVE.md`.
