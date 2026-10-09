# Production readiness roadmap

Demo green-light (mock OTP + mock MoMo) is separate from production go-live.
Use this checklist to move Wamu from Kampala demo → staging → production.

## Current demo mode (OK for pitches)

| Flag | Default | Meaning |
|------|---------|---------|
| `OTP_MOCK_MODE=true` | on | OTP always `123456` |
| `PAYMENT_MOCK_AUTO_SUCCESS=true` | on | MoMo collections auto-SUCCESS |
| `S3_ENABLED=false` | off | Media on local disk `/media-files` |
| Quick Cloudflare tunnel | rotating URL | Fine for demos, not for users |

## Stage A — Staging (real rails, fake money)

1. **Hosting**
   - Deploy API + Postgres + Redis (Docker staging compose or VM)
   - Named tunnel or real HTTPS domain (`setup_named_tunnel.sh` / Caddy)
2. **OTP**
   - Set `OTP_MOCK_MODE=false`
   - Configure Africa's Talking username + API key + sender
   - Verify request/verify on a real Ugandan number
3. **Payments (sandbox)**
   - Set `PAYMENT_MOCK_AUTO_SUCCESS=false`
   - MTN MoMo Collections sandbox credentials
   - Webhook URL reachable + `PAYMENT_WEBHOOK_SECRET`
   - Smoke: create order → collect → webhook/refresh → SUCCESS → merchant payout enqueue
4. **Media**
   - `S3_ENABLED=true` + MinIO or S3 bucket
   - Confirm upload + Discover playback via public media URLs
5. **CI**
   - `pytest` green
   - `./infrastructure/phone_demo_greenlight.sh https://staging…`

## Stage B — Production gates

From `app/core/config.py` production validator — must be true before launch:

- `DEBUG=false`
- `OTP_MOCK_MODE=false`
- `PAYMENT_MOCK_AUTO_SUCCESS=false`
- Strong `SECRET_KEY` (≥32 chars)
- Explicit `CORS_ORIGINS` (no `*`)
- Strong `PAYMENT_WEBHOOK_SECRET`

Also:

- Backups for Postgres
- Log/metrics (already has `/metrics`)
- FCM server key for real push (optional at soft launch)
- TURN for WebRTC calls on carrier NAT

## Stage C — Soft launch wedge

Keep scope narrow:

**Discover short video → Chat to Order → Pay → Rider delivery**

Do not expand modules until this loop is stable on real OTP + MoMo sandbox for 2 weeks.

## Commands

```bash
# Functional green-light (demo or staging URL)
./infrastructure/phone_demo_greenlight.sh
./infrastructure/phone_demo_greenlight.sh https://your-staging-host

# Backend unit/integration
cd wamu-backend && .venv/bin/pytest -q

# Demo ready
./infrastructure/phone_demo_ready.sh
```
