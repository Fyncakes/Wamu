# Wamu on Hetzner Cloud

Cost-light production/staging host while GCP billing is blocked (Uganda TIN).

| Piece | Service |
|-------|---------|
| VPS | Hetzner **CX23** (~$7–10/mo with IPv4 + VAT) |
| Stack | Docker Compose: API, Celery worker/beat, Postgres, Redis, MinIO, Caddy |
| HTTPS | Caddy + Let’s Encrypt on `api.wamu.ug` (or Cloudflare tunnel) |

## Account

- Console: https://console.hetzner.cloud
- Accounts: https://accounts.hetzner.com (login email used at signup)

## Provision

```bash
# Install CLI: https://github.com/hetznercloud/cli#installation
hcloud context create wamu
chmod +x infrastructure/hetzner/provision.sh infrastructure/hetzner/deploy.sh
./infrastructure/hetzner/provision.sh
```

## Deploy

```bash
# Edit infrastructure/hetzner/.env.hetzner — set PUBLIC_API_BASE after DNS
export HETZNER_HOST=root@YOUR_SERVER_IP
export WAMU_DOMAIN=api.wamu.ug   # optional if using Caddy LE
./infrastructure/hetzner/deploy.sh
```

Smoke:

```bash
curl -sS "https://api.wamu.ug/api/v1/health" | python3 -m json.tool
./infrastructure/verify_deploy.sh "https://api.wamu.ug"
```

Point Flutter:

```bash
cd wamu-mobile
flutter run --dart-define=API_BASE_URL=https://api.wamu.ug
```

## DNS

Create an A record: `api.wamu.ug` → server IPv4. Caddy issues certificates automatically.

If DNS is not ready yet, use the existing Cloudflare tunnel scripts under `infrastructure/` and set `PUBLIC_API_BASE` to the tunnel HTTPS URL.

## Cost guardrails

- One CX23 only; no managed DB/Redis
- Keep `OTP_MOCK_MODE=true` / `PAYMENT_MOCK_AUTO_SUCCESS=true` until MoMo callbacks point at the new HTTPS base
