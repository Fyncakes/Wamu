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

## Airtel (later)

Do not block Railway launch on Airtel. When you need it, use a VPS with a fixed egress IP (`infrastructure/hetzner/`) or Railway Pro static outbound IPs, then follow [`AIRTEL_PORTAL_CHECKLIST.md`](./AIRTEL_PORTAL_CHECKLIST.md).
