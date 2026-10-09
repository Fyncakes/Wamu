# MVP v1.0 — Private Beta Checklist (A–I Harden)

Track owned by this doc: harden Identity→Admin for a **private beta**.  
Hard deferrals: E2EE, Mini Apps, custodial wallet, rides, developer portal, fake CARD PSP.

Source plan: MVP A–I Harden. Phase 0 remains the security floor — see [PHASE0_STABILIZATION.md](PHASE0_STABILIZATION.md).

---

## A–I exit criteria

| Area | Private-beta bar | Status |
|------|------------------|--------|
| **A Identity** | Live SMS OTP path (Africa's Talking) when `OTP_MOCK_MODE=false`; mock still default locally | Code ready — fill `AFRICASTALKING_*` |
| **B Messaging** | Block enforced on DM/send; report from chat; group admin kick | Done |
| **C Status** | Audience `CONTACTS` (default) / `EVERYONE`; no global leak; TEXT/IMAGE only | Done |
| **D Communities** | Group creator = ADMIN; kick member | Done |
| **E Discover** | Existing category/search (PostGIS deferred) | Baseline OK |
| **F Commerce** | Address required for DELIVERY; no demo cart theater; unpaid fulfill gated | Done |
| **G Payments** | Mock dry-run + MoMo sandbox path when keys set | See [PAYMENTS_STAGING.md](PAYMENTS_STAGING.md) |
| **H Notifications** | FCM when `FCM_SERVER_KEY` + `flutterfire configure`; order status push enqueue; foreground inbox refresh | Soft-wire ready |
| **I Admin** | Suspend/activate users; reports list/resolve; health rails panel | Done |

---

## Ops sequence

```bash
# 1) Local / no Docker
./wamu-backend/scripts/run_local.sh
./infrastructure/verify_deploy.sh

# 2) Staging compose (needs docker group)
sudo usermod -aG docker "$USER"   # once, then re-login
./infrastructure/staging_up.sh
./infrastructure/verify_deploy.sh

# 3) Live OTP (optional)
# In infrastructure/.env.staging:
#   OTP_MOCK_MODE=false
#   AFRICASTALKING_USERNAME=...
#   AFRICASTALKING_API_KEY=...

# 4) MoMo sandbox (optional)
#   PAYMENT_MOCK_AUTO_SUCCESS=false
#   fill MTN_* / AIRTEL_*
#   python -m scripts.payments_dry_run --base http://127.0.0.1:8000  # then MTN provider

# 5) Real FCM (optional)
#   FCM_SERVER_KEY=...
#   cd wamu-mobile && flutterfire configure
```

Rails flags: `GET /api/v1/health/rails` → `ready_for_live_otp`, `ready_for_momo_sandbox`, `fcm_server_key_set`.

---

## Explicitly not in this beta

- Card payments, PostGIS near-me, Signal E2EE, Mini Apps, wallet, rides, developer portal.
- Status video (photo + text only).

**Rule:** Do not start Phase 2–4 until staging OTP + MoMo + FCM are boringly reliable with real devices.
