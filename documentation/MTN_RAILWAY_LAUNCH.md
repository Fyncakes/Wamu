# MTN-first launch on Railway

Use this path for the **free Railway trial**. **Airtel Money is deferred** on hosted staging (IP allowlist + portal friction). Customers and testers should pay with **MTN MoMo**. Airtel remains in code for later — see [`AIRTEL_PORTAL_CHECKLIST.md`](./AIRTEL_PORTAL_CHECKLIST.md) when you move to Hetzner/GCP with static egress.

## Order of operations

1. Deploy API on Railway — [`infrastructure/railway/README.md`](../infrastructure/railway/README.md).
2. Generate env locally:

   ```bash
   ./infrastructure/railway/bootstrap_env.sh
   ```

   Paste printed variables into Railway (**wamu-api** and **wamu-worker**). Set `PUBLIC_API_BASE` after you generate the public domain.

3. **MTN sandbox** (optional while mocks are on):
   - [MoMo Developer](https://momodeveloper.mtn.com/) → subscription key.
   - In Railway variables: `MTN_SUBSCRIPTION_KEY`, `MTN_BASE_URL=https://sandbox.momodeveloper.mtn.com`, `MTN_TARGET_ENVIRONMENT=sandbox`.
   - Register callback host = your Railway hostname (no `https://`, no path), e.g. `wamu-api-production.up.railway.app`.
   - From laptop with keys in env: `cd wamu-backend && python scripts/provision_mtn_sandbox.py` → paste `MTN_API_USER` / `MTN_API_KEY` into Railway.
   - Set `PAYMENT_MOCK_AUTO_SUCCESS=false` when ready; keep `OTP_MOCK_MODE=true` until Africa's Talking is wired.
   - Webhook URL: `{PUBLIC_API_BASE}/api/v1/payments/webhooks/MTN` with `MTN_WEBHOOK_SECRET`.

4. **Flutter APK** (MTN-only UI by default):

   ```bash
   cd wamu-mobile
   flutter build apk --release \
     --dart-define=API_BASE_URL=https://YOUR.up.railway.app
   ```

   To show Airtel in the picker again (local mock): `--dart-define=MOMO_AIRTEL_ENABLED=true`.

5. Verify: `./infrastructure/verify_deploy.sh https://YOUR.up.railway.app`

## Production Uganda (UGX + real MoMo PIN)

Sandbox **cannot** take UGX or prompt a real handset. Live Collections needs MTN
business onboarding — Wamu code is already ready (`EUR` only while
`MTN_TARGET_ENVIRONMENT=sandbox`).

### What you must get from MTN (outside this repo)

1. Submit **Go Live** / KYC on [momodeveloper.mtn.com/golive](https://momodeveloper.mtn.com/golive) (Uganda docs).
2. After approval, MTN creates:
   - Production developer account → [momoapi.mtn.com](https://momoapi.mtn.com/) (or AF/EU regional portal) → **Profile** → **Collections subscription key**
   - Partner Portal access (Uganda example: [mobilemoneyreadonly.mtn.co.ug](https://mobilemoneyreadonly.mtn.co.ug)) — username from your account manager + OTP to a registered MTN SIM
3. In Partner Portal → **API Access** → **Create API User**:
   - **Provider Callback Host** = `wamu-production.up.railway.app` (hostname only)
   - **Payment Server URL** = `https://wamu-production.up.railway.app/api/v1/payments/webhooks/MTN`
   - Save **API User** + **API Key** (key shown once)
4. Ask MTN to **whitelist Railway egress IPs** (or move API to Hetzner fixed IP — see `infrastructure/hetzner/`). Non-whitelisted IPs are rejected in production even with valid keys.
5. Optional: same flow for **Disbursement** product (separate subscription key + API user).

Official config table ([MoMo Dev Community](https://momodevelopercommunity.mtn.com/how-to-59/momo-api-production-configuration-101)):

| | Sandbox | Production (Uganda) |
| --- | --- | --- |
| Base URL | `https://sandbox.momodeveloper.mtn.com` | `https://proxy.momoapi.mtn.com` |
| `X-Target-Environment` | `sandbox` | `mtnuganda` |
| Currency | EUR | UGX |
| MSISDN | any / test | `2567…` (digits, no `+`) |

### Railway flip (only after keys are in hand)

Set on the **Wamu** service (redeploy):

```bash
MTN_BASE_URL=https://proxy.momoapi.mtn.com
MTN_TARGET_ENVIRONMENT=mtnuganda
MTN_SUBSCRIPTION_KEY=<production Collections primary key>
MTN_API_USER=<partner-portal API user UUID>
MTN_API_KEY=<partner-portal API key>
MTN_WEBHOOK_SECRET=<long random ≥24 chars>
PUBLIC_API_BASE=https://wamu-production.up.railway.app
PAYMENT_MOCK_AUTO_SUCCESS=false
PAYOUT_AUTO_EXECUTE=false   # queue merchant payouts until first live Execute works
```

Wamu then sends **UGX** automatically (sandbox EUR remap no longer applies). Verify:

```bash
curl -sS https://wamu-production.up.railway.app/api/v1/health/rails
# expect ready_for_momo_sandbox / collections configured true
```

Tiny live test: Pay with your own MTN number → USSD/PIN on phone → webhook or refresh → SUCCESS.

## Airtel (later)

Do not block Railway launch on Airtel. When you need it, use a VPS with a fixed egress IP (`infrastructure/hetzner/`) or Railway Pro static outbound IPs, then follow [`AIRTEL_PORTAL_CHECKLIST.md`](./AIRTEL_PORTAL_CHECKLIST.md).
