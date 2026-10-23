# Live OTP for users (login + MTN MoMo)

Wamu uses **two different** “OTP” flows:

| Flow | What the user sees | What you configure |
|------|-------------------|-------------------|
| **Login / sign-up** | 6-digit **SMS** on their phone (MTN, Airtel, etc.) | `OTP_MOCK_MODE=false` + **Africa's Talking** (`AFRICASTALKING_*`) |
| **Pay with MTN MoMo** | **Approve on phone** (MoMo PIN / prompt), not an in-app code | `PAYMENT_MOCK_AUTO_SUCCESS=false` + **MTN sandbox/prod** (`MTN_*`) + public `PUBLIC_API_BASE` |

There is **no MTN SMS API** for login in Wamu today — SMS goes through [Africa's Talking](https://africastalking.com/) to any Ugandan number.

## Turn on real login SMS (recommended before public beta)

1. Create an Africa's Talking account (Uganda), enable **SMS**, copy **username** + **API key**. Optional: register sender ID **WAMU**.
2. On the **API host** (DigitalOcean `.env.do` or local `.env`):

   ```bash
   OTP_MOCK_MODE=false
   AFRICASTALKING_USERNAME=sandbox   # or your live username
   AFRICASTALKING_API_KEY=your_key
   AFRICASTALKING_SENDER_ID=WAMU     # if approved
   ```

3. Redeploy / restart API. Check:

   ```bash
   curl -sS "$PUBLIC_API_BASE/api/v1/health/rails" | python3 -m json.tool
   # ready_for_live_otp: true
   ```

4. App: the login screen asks for the SMS code. It does not show a demo code.

Helper (local `.env.do` only):

```bash
export AFRICASTALKING_USERNAME=...
export AFRICASTALKING_API_KEY=...
./infrastructure/digitalocean/enable_live_otp.sh
./infrastructure/digitalocean/deploy.sh
```

## Turn on MTN MoMo (payment approval on phone)

1. [MoMo Developer](https://momodeveloper.mtn.com/) subscription key + sandbox API user/key (`scripts/provision_mtn_sandbox.py`).
2. Set on API:

   ```bash
   PAYMENT_MOCK_AUTO_SUCCESS=false
   MTN_SUBSCRIPTION_KEY=...
   MTN_API_USER=...
   MTN_API_KEY=...
   MTN_WEBHOOK_SECRET=...
   MTN_BASE_URL=https://sandbox.momodeveloper.mtn.com
   MTN_TARGET_ENVIRONMENT=sandbox
   PUBLIC_API_BASE=https://api.wamu.ug   # HTTPS, reachable by MTN
   ```

3. Whitelist droplet **egress IP** in MoMo portal; callback `{PUBLIC_API_BASE}/api/v1/payments/webhooks/MTN`.

Checkout with **MTN** shows *“Approve on your MTN MoMo phone”* while status is PENDING — not the in-app MoMo OTP dialog (that path is **mock Airtel only**).

## Still on mock (safe default)

`OTP_MOCK_MODE=true` → SMS is not sent. The API does not return the code. Automated tests still know the fixture code; the app does not.  
`PAYMENT_MOCK_AUTO_SUCCESS=true` → Airtel mock theater; MTN still hits live API if `MTN_*` are set.
