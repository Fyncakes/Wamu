# Wamu phone demo — ready checklist

Goal: open one URL on a phone and walk **Discover → Chat to Order → Pay (mock) → My Videos** without fighting dead tunnels.

## Quick start (every demo)

```bash
# From repo root — ensure API + public URL + smoke
./infrastructure/phone_demo_ready.sh

# After UI code changes
./infrastructure/phone_demo_ready.sh --rebuild

# If Chrome Error 1033 / health fails
./infrastructure/phone_demo_ready.sh --restart-tunnel
```

Open the printed URL (also in `dist/DEMO_URL.txt` / `dist/ACCESS.md`).

| Item | Value |
|------|--------|
| OTP (mock) | `123456` |
| Local API | `http://127.0.0.1:8000` |
| Stop tunnel/watchdog | `./infrastructure/phone_demo_down.sh` |

## Smoke checks

```bash
./infrastructure/phone_demo_smoke.sh
./infrastructure/phone_demo_smoke.sh "$(cat dist/DEMO_URL.txt)"
```

Verifies: public health, Flutter `/`, OTP login, Discover feed, video byte-range, poster, businesses/products/orders.

## Fixed public URL (recommended)

Quick tunnels rotate. For a stable hostname:

1. Cloudflare account + domain (or CF-managed zone)
2. One-time:

```bash
./infrastructure/setup_named_tunnel.sh --hostname wamu-demo.yourdomain.com
```

3. Then `./infrastructure/phone_demo_up.sh` / `phone_demo_ready.sh` reuse that hostname.

## Full bring-up (cold machine)

```bash
./infrastructure/phone_demo_up.sh   # API + Flutter web build + tunnel + watchdog
./infrastructure/phone_demo_smoke.sh
```

## 5-minute walkthrough

1. Phone Chrome → `DEMO_URL` → OTP `123456`
2. **Videos** tab — first clip should start quickly; swipe once (preload)
3. **Chat to Order** on a clip → send a product interest
4. Checkout / Pay (mock MoMo) → order appears
5. Business owner → **My Videos** → Publish / Archive / Restore

## If something breaks

| Symptom | Fix |
|---------|-----|
| Error 1033 / blank | `phone_demo_ready.sh --restart-tunnel` |
| Old UI after code change | `phone_demo_ready.sh --rebuild` then hard-refresh |
| Videos timeout | Check smoke “video range”; re-run ready; avoid huge uploads |
| API down | `curl -sf http://127.0.0.1:8000/api/v1/health` then ready script |

Keep the **PC awake** during demos.
