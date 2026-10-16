# Phase C — Live disbursement go-live checklist

Wamu code is ready for live MoMo **Disbursement**. Remaining blockers are
**provider onboarding / credentials**, not product gaps.

## What is already built

| Piece | Status |
|-------|--------|
| Collection adapters (MTN / Airtel / MOCK) | ✅ |
| Disbursement adapters + status poll | ✅ |
| Optional dedicated `MTN_DISBURSEMENT_*` keys | ✅ |
| `X-Callback-Url` when `PUBLIC_API_BASE` is public | ✅ |
| Queue when `PAYOUT_AUTO_EXECUTE=false` | ✅ |
| Admin **Execute** one / batch from Reconciliation | ✅ |
| Ledger settle on SUCCESS / reverse | ✅ |
| Failed-payout merchant notification | ✅ |
| Celery reconcile payments + payouts + statements | ✅ |
| `/health/rails` → `ready_for_live_disbursement` | ✅ |
| Rider delivery-fee payouts (queue + execute) | ✅ |
| Owner commission withdraw (`OWNER_PAYOUT_PHONE`) | ✅ |
| MTN / Airtel collection **refund** adapters | ✅ |
| Rider payout destination (app + API) | ✅ |
| Admin manual-refund ops queue | ✅ |
| Statement JSON import (admin) | ✅ |
| `staging_readiness --strict-disbursement` | ✅ |

## Credentials you still need from MTN / Airtel

### MTN MoMo

1. Collections product: `MTN_SUBSCRIPTION_KEY`, `MTN_API_USER`, `MTN_API_KEY`
2. **Disbursement** product (preferred separate keys):
   - `MTN_DISBURSEMENT_SUBSCRIPTION_KEY`
   - `MTN_DISBURSEMENT_API_USER`
   - `MTN_DISBURSEMENT_API_KEY`
3. Webhook / callback secret → `MTN_WEBHOOK_SECRET`
4. Register callback URL: `{PUBLIC_API_BASE}/api/v1/payments/webhooks/MTN`
5. Sandbox → production: set `MTN_BASE_URL` + `MTN_TARGET_ENVIRONMENT=mtnuganda`

### Airtel Money

1. `AIRTEL_CLIENT_ID` / `AIRTEL_CLIENT_SECRET`
2. `AIRTEL_DISBURSEMENT_PIN` (required in production)
3. `AIRTEL_WEBHOOK_SECRET`
4. Callback: `{PUBLIC_API_BASE}/api/v1/payments/webhooks/AIRTEL`

### Owner commission

```
OWNER_PAYOUT_PHONE=+2567…
OWNER_PAYOUT_PROVIDER=MTN
```

## Staging flip (when keys arrive)

```bash
PAYMENT_MOCK_AUTO_SUCCESS=false
PAYOUT_AUTO_EXECUTE=false          # keep queue; Execute from admin first
PUBLIC_API_BASE=https://api.your-staging.host
# fill MTN_* / AIRTEL_* / webhook secrets
```

Verify:

```bash
curl -s https://api.your-staging.host/api/v1/health/rails | jq '.ready_for_live_disbursement, .mtn_disbursement_configured'
```

Then:

1. Paid test order → collection webhook SUCCESS → payout lands in **queue**
2. Admin → Reconciliation → **Execute** one payout
3. Confirm merchant phone credit + ledger merchant_payable drops
4. Only then consider `PAYOUT_AUTO_EXECUTE=true`

## Compliance

BoU / AML / KYC and MoMo business onboarding remain **outside** this codebase.
Do not enable wallet custody — float stays at the licensed provider.
