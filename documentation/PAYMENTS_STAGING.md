# WAMU Payments — Staging MoMo (MTN / Airtel)

**Principle:** Wamu never custodies funds. Collections go through licensed providers; SUCCESS only from verified webhooks or provider API.

## Mock dry-run (no MoMo keys)

Verifies **order → MOCK payment SUCCESS → merchant payout** before sandbox credentials arrive.

```bash
# Against a running API (OTP mock + catalog seeded)
cd wamu-backend && source .venv/bin/activate
python -m scripts.bootstrap   # if needed
uvicorn app.main:app --reload --host 127.0.0.1 --port 8000

# Another terminal:
python -m scripts.payments_dry_run --base http://127.0.0.1:8000
python -m scripts.staging_readiness --url http://127.0.0.1:8000
# or: curl -s http://127.0.0.1:8000/api/v1/health/rails | jq
```

Automated coverage: `tests/test_payments_dry_run.py`.

When `ready_for_momo_sandbox` is true on `/health/rails`, repeat the dry-run with real MTN sandbox phones and `provider=MTN` (PENDING until webhook / reconcile).

## Live SMS OTP (Identity)

When leaving mock OTP:

```bash
OTP_MOCK_MODE=false
AFRICASTALKING_USERNAME=...
AFRICASTALKING_API_KEY=...
# optional sender ID:
AFRICASTALKING_SENDER_ID=WAMU
```

`GET /health/rails` exposes `sms_provider_configured` and `ready_for_live_otp`. The API never returns the OTP code when mock is off (`mock_hint` is null).

## Local demo

`PAYMENT_MOCK_AUTO_SUCCESS=true` → MTN/AIRTEL labeled mocks auto-confirm (theatre for Flutter cart).

## Staging (real adapters, no fake SUCCESS)

```bash
PAYMENT_MOCK_AUTO_SUCCESS=false
PAYMENT_WEBHOOK_SECRET=<lab hmac>
MTN_SUBSCRIPTION_KEY=...
MTN_API_USER=...
MTN_API_KEY=...
MTN_WEBHOOK_SECRET=...
MTN_BASE_URL=https://sandbox.momodeveloper.mtn.com
MTN_TARGET_ENVIRONMENT=sandbox

AIRTEL_CLIENT_ID=...
AIRTEL_CLIENT_SECRET=...
AIRTEL_WEBHOOK_SECRET=...
AIRTEL_BASE_URL=https://openapiuat.airtel.africa
```

Initiate returns **PENDING**; callbacks hit:

`POST /api/v1/payments/webhooks/MTN`  
`POST /api/v1/payments/webhooks/AIRTEL`

### Signature headers

| Provider | Header | Secret env |
|----------|--------|------------|
| MOCK / lab | `X-Wamu-Signature: sha256=<hmac>` | `PAYMENT_WEBHOOK_SECRET` |
| MTN | `X-MTN-Signature` or `X-Callback-Signature` | `MTN_WEBHOOK_SECRET` |
| Airtel | `X-Airtel-Signature` | `AIRTEL_WEBHOOK_SECRET` |

HMAC = SHA-256 of **raw request body**.

Provider JSON is normalized into Wamu `{event_id, provider_reference, status, amount}`.

## Reconciliation (Celery)

Open `PENDING` / `PROCESSING` payments are polled via provider `check_status` and expired after 24h if still open.

| Mechanism | Detail |
|-----------|--------|
| Celery Beat | every 5 minutes + nightly 02:15 Africa/Kampala |
| Task | `wamu.reconcile_payments` |
| Admin | `POST /api/v1/admin/payments/reconcile` (JWT admin) |

## Merchant payouts (non-custodial)

After collection **SUCCESS**, Wamu instructs MoMo **Disbursement** to the business payee — no wallet balance on Wamu.

| Piece | Detail |
|-------|--------|
| Destination | `Business.payout_phone` → else `phone` → else owner phone |
| Provider | `Business.payout_provider` or same rail as collection |
| Merchant UI | Flutter **Business Owner → Payout settings** (`/business-owner/payouts`) |
| Model | `MerchantPayout` (1:1 with successful `Payment`) |
| Net amount | `amount = collection − platform_fee` (`PLATFORM_FEE_BPS`, default `0`) |
| Fee | Recorded on payout (`platform_fee`, `fee_bps`); retained in MoMo float |
| Adapters | `app/integrations/payments/disbursement.py` (MOCK / MTN / Airtel) |
| Trigger | payment webhook / reconcile / mock auto-success |
| Owner API | `GET /api/v1/businesses/{id}/payouts` |
| Admin | `GET /admin/payouts`, `POST /admin/payouts/reconcile`, `POST /admin/payouts/{id}/retry` |
| Celery | `wamu.reconcile_payouts` every 5m + nightly 02:30 |

Disbursement callbacks reuse `POST /payments/webhooks/{provider}` — if collection reference is unknown, lookup tries `MerchantPayout`.

Set `PLATFORM_FEE_BPS=250` for a 2.5% cut. Fee is never credited to a Wamu user wallet.

## Admin visibility

`GET /api/v1/admin/stats` returns:

| Field | Meaning |
|-------|---------|
| `revenue_ugx` | Sum of SUCCESS collection amounts (GMV) |
| `platform_fee_ugx` | Sum of SUCCESS payout `platform_fee` |
| `payout_net_ugx` | Sum of SUCCESS payout net amounts |
| `successful_payouts` | Count of SUCCESS disbursements |

Admin UI: Dashboard cards + **Payouts** page (`/payouts`) with retry / reconcile.

## Staging compose

Preferred: `./infrastructure/staging_up.sh` (see `documentation/DEPLOY.md`).

```bash
cp infrastructure/.env.staging.example infrastructure/.env.staging
# fill MTN_* / AIRTEL_* / PAYMENT_WEBHOOK_SECRET when leaving mock mode
docker compose -f infrastructure/docker-compose.staging.yml --env-file infrastructure/.env.staging up -d --build
```

Stack: Postgres, Redis, MinIO, API, Celery **worker** + **beat**.

## Compliance reminder

BoU licensing / AML / KYC before live money. Do not enable wallet custody in this layer.
Platform fee via `PLATFORM_FEE_BPS` deducts from merchant disbursement only — float remains at the licensed provider.
