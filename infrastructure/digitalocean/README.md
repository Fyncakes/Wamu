# Wamu on DigitalOcean

**Recommended:** one **Droplet** + Docker Compose (API, Celery, Postgres, Redis, MinIO, Caddy). Fixed **IPv4** for MTN MoMo allowlisting. Budget about **$12/mo** (`s-1vcpu-2gb`) plus domain.

**Not recommended for MVP:** [App Platform](https://docs.digitalocean.com/products/app-platform/) with separate managed DB + worker + admin — cost adds up quickly vs one VPS. Use App Platform later only for `wamu-admin` if needed.

Railway is **deprecated** for Wamu launch; see `infrastructure/railway/` for history only.

## 1. Account and droplet

1. Sign up: [cloud.digitalocean.com](https://cloud.digitalocean.com/)
2. Add an **SSH key** (Settings → Security → SSH keys) — same key as your laptop (`~/.ssh/id_ed25519.pub`).
3. **Create Droplet**
   - **Image:** Ubuntu 24.04 LTS  
   - **Size:** Basic **2 GB / 1 vCPU** (`s-1vcpu-2gb`) minimum for API + worker + Postgres  
   - **Region:** closest to Uganda (often **London `lon1`** or **Frankfurt `fra1`**)  
   - **Authentication:** SSH key only (disable password login after first boot if you use password)  
   - **Hostname:** `wamu-api`

Optional CLI:

```bash
doctl auth init   # paste Personal Access Token
chmod +x infrastructure/digitalocean/provision.sh infrastructure/digitalocean/deploy.sh
./infrastructure/digitalocean/provision.sh
```

## 2. Firewall (control panel)

Networking → **Firewalls** → create `wamu-web`:

| Inbound | TCP | 22 | your home IP if possible, else 0.0.0.0/0 |
| Inbound | TCP | 80 | 0.0.0.0/0 |
| Inbound | TCP | 443 | 0.0.0.0/0 |

Attach the firewall to the `wamu-api` droplet. **Do not** expose Postgres/Redis/MinIO ports publicly (Compose keeps them internal).

## 3. Secrets and env

On your laptop (repo root):

```bash
./infrastructure/digitalocean/bootstrap_env.sh
# edits infrastructure/digitalocean/.env.do — set PUBLIC_API_BASE after DNS
```

Set after you know the public URL:

- `PUBLIC_API_BASE=https://api.wamu.ug` (no trailing slash)  
- `PUBLIC_MEDIA_BASE` same  
- `WAMU_DOMAIN=api.wamu.ug`

First launch: keep `OTP_MOCK_MODE=true` and `PAYMENT_MOCK_AUTO_SUCCESS=true`.  
**Real SMS login OTP:** [`documentation/LIVE_USER_OTP.md`](../../documentation/LIVE_USER_OTP.md) + `./enable_live_otp.sh` after Africa's Talking keys.  
**MTN MoMo pay:** [`documentation/MTN_DIGITALOCEAN_LAUNCH.md`](../../documentation/MTN_DIGITALOCEAN_LAUNCH.md).

## 4. Deploy

```bash
export DO_HOST=root@YOUR_DROPLET_IP
export WAMU_DOMAIN=api.wamu.ug   # optional; must match DNS for TLS
./infrastructure/digitalocean/deploy.sh
```

First run installs Docker on the droplet, rsyncs `wamu-backend` + this folder, runs `docker compose up -d --build`.

## 5. DNS and TLS

1. **A record:** `api.wamu.ug` → droplet **IPv4** (DigitalOcean → Droplet → copy IP).  
2. Caddy in Compose requests **Let’s Encrypt** certs automatically once DNS propagates.  
3. Redeploy or `docker compose restart caddy` if you changed `WAMU_DOMAIN` after first boot.

Smoke:

```bash
curl -sS "https://api.wamu.ug/api/v1/health"
./infrastructure/verify_deploy.sh "https://api.wamu.ug"
```

**MTN sandbox:** whitelist this droplet’s **outbound** IP in MoMo portal (curl `https://api.ipify.org` from the droplet). Callback URL: `{PUBLIC_API_BASE}/api/v1/payments/webhooks/MTN`.

## 6. Flutter / Play

```bash
cd wamu-mobile
flutter build apk --release --dart-define=API_BASE_URL=https://api.wamu.ug
```

## 7. Admin website (`wamu-admin`)

The default stack is **API-only**. To host the Next.js admin:

- Build with `NEXT_PUBLIC_API_URL=https://api.wamu.ug` and deploy to **App Platform** (static/Node) or a second tiny Droplet; or run admin locally against the public API.

## Ops

| Task | Command (on droplet) |
|------|----------------------|
| Logs | `cd /opt/wamu/infrastructure/digitalocean && docker compose logs -f api` |
| Redeploy | Re-run `deploy.sh` from laptop |
| Shell | `ssh root@IP` |

## Cost (approx.)

| Item | USD/mo |
|------|--------|
| Droplet s-1vcpu-2gb | ~12 |
| Backups (optional) | +20% of droplet |
| Managed DB | skip — Postgres in Compose |

Compare: Hetzner CX23 (`infrastructure/hetzner/`) is similar; pick whichever account/billing works in Uganda.
