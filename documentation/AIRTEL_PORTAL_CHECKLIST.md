# Airtel portal checklist (Wamu — Uganda)

Portal app: **Wamu** · Merchant code: **ZQFFIPWY** · Egress IP to whitelist: **160.119.148.21**

Code adapters are ready. You still finish portal + paste secrets into `wamu-backend/.env`.

## You must do in the portal (I cannot)

1. **Mode** — You are on **PROD**. That is fine for live keys; keep it if Airtel already approved production. Prefer **TEST/UAT** first if status is still `NA` / not approved.
2. **Whitelist IP** — For **Collection-APIs** and **Disbursement-APIs** → **Settings** → Security / IP whitelist → add `160.119.148.21` (this PC’s public IP). Without this, token and payment calls fail from here.
3. **Key Management** — Eye icon → copy **Client ID** and **Client Secret**.
4. **Disbursement-APIs → Settings** — set / copy **Disbursement PIN**. Accept **v2.0** update if prompted.
5. **Callback URL** (when you have a public HTTPS API, e.g. Cloud Run — not localhost):
   `{PUBLIC_API_BASE}/api/v1/payments/webhooks/AIRTEL`
6. Confirm app / products are **Approved** (or Partially Approved for TEST). Status `NA` often means calls will be rejected until Airtel finishes onboarding.

## Paste into `wamu-backend/.env`

```bash
AIRTEL_CLIENT_ID=<from Key Management>
AIRTEL_CLIENT_SECRET=<from Key Management>
AIRTEL_DISBURSEMENT_PIN=<from Disbursement Settings>
# already scaffolded locally:
# AIRTEL_BASE_URL=https://openapi.airtel.africa   # PROD
# AIRTEL_WEBHOOK_SECRET=<generated>
# AIRTEL_COUNTRY=UG
# AIRTEL_CURRENCY=UGX
# AIRTEL_SIGN_COLLECTIONS=true
```

Do **not** commit `.env`. You can paste the three values here in chat if you want them written for you.

## Then I / you run

```bash
cd wamu-backend && source .venv/bin/activate
python scripts/check_airtel_sandbox.py
# live smokes (Airtel test numbers or your Airtel line):
python scripts/check_airtel_sandbox.py --collect 752604392 --amount 500
python scripts/check_airtel_sandbox.py --disburse 752604392 --amount 500
```

Keep `PAYMENT_MOCK_AUTO_SUCCESS=false` and `PAYOUT_AUTO_EXECUTE=false` until collection + one admin-executed payout succeed.

## Later (GCP)

When the API moves off this laptop, whitelist the **Cloud Run / NAT static egress IP** instead of (or in addition to) `160.119.148.21`, and set `PUBLIC_API_BASE` to that HTTPS URL for callbacks.
