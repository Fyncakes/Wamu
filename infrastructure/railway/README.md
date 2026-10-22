# Wamu API on Railway (trial / hobby)

Deploy the shared staging API from [Railway](https://railway.com/dashboard) using the existing `wamu-backend/Dockerfile`. Good for a **free trial** ($5 credit, 30 days — see [Railway pricing](https://docs.railway.com/pricing/free-trial)) before you finish Hetzner/GCP billing.

**Do not** point Play Store or MoMo callbacks at your laptop. Use the Railway **public HTTPS domain** as `PUBLIC_API_BASE`.

## What you get vs full Docker Compose staging

| Piece | Local `docker-compose.staging.yml` | Railway trial |
|-------|-----------------------------------|---------------|
| API + migrations + seed | yes | yes (GitHub deploy) |
| Postgres / Redis | yes | managed plugins |
| Celery worker + beat | 2 containers | **1** service (`worker-beat`) |
| MinIO / `S3_ENABLED` | yes | **skip** — leave `S3_ENABLED=false` |
| Stable outbound IP (Airtel whitelist) | VPS / Hetzner | **not on trial** — see [Airtel](#airtel-and-momo) |

Trial projects are limited to **5 services per project**. This layout uses exactly four:

1. **wamu-api** — GitHub repo, root directory `wamu-backend`, Dockerfile default CMD  
2. **wamu-worker** — same repo/root, start command `/app/scripts/entrypoint_celery.sh worker-beat`  
3. **PostgreSQL** — Railway database  
4. **Redis** — Railway database  

## Prerequisites

- GitHub repo pushed (this monorepo is fine).
- Connect GitHub on Railway for **full trial** network access ([limited trial](https://docs.railway.com/pricing/free-trial) blocks most outbound calls — bad for MoMo even in sandbox).
- Secrets ready: copy from `infrastructure/railway/env.reference.example` and generate `SECRET_KEY` / webhook secrets like `infrastructure/.env.staging.example`.

## Step-by-step (dashboard)

### 1. Create project

1. Open [Railway dashboard](https://railway.com/dashboard) → **New Project**.
2. Prefer **Deploy from GitHub repo** and select **WAMU** (or your fork).

### 2. Add databases

In the project:

1. **+ New** → **Database** → **PostgreSQL**.
2. **+ New** → **Database** → **Redis**.

Railway exposes `DATABASE_URL` and `REDIS_URL` on each plugin.

### 3. API service (`wamu-api`)

1. **+ New** → **GitHub Repo** → same repo (or add a second service from the first deploy).
2. **Settings → Build**:
   - **Root Directory:** `wamu-backend`
   - **Dockerfile Path:** `Dockerfile` (default)
3. **Settings → Deploy** — leave start command empty (uses `scripts/entrypoint.sh`; respects `PORT`).
4. **Variables** — set shared app env (see [Environment variables](#environment-variables)). Wire DB/Redis:

   | Variable | Value |
   |----------|--------|
   | `DATABASE_URL` | Reference `${{Postgres.DATABASE_URL}}` then fix driver — see below |
   | `REDIS_URL` | `${{Redis.REDIS_URL}}` |
   | `CELERY_BROKER_URL` | Same Redis URL with DB `1`, e.g. copy `REDIS_URL` and change trailing `/0` → `/1` |

   **Async driver:** Wamu expects SQLAlchemy async URLs. If Postgres gives `postgresql://…`, set:

   ```text
   postgresql+asyncpg://USER:PASS@HOST:PORT/railway
   ```

   (Replace `postgresql://` with `postgresql+asyncpg://`; keep user/password/host/db from the plugin.)

5. **Settings → Networking** → **Generate Domain** → note `https://….up.railway.app`.
6. Set **`PUBLIC_API_BASE`** to that URL (no trailing slash), redeploy if you added it after first deploy.

### 4. Worker service (`wamu-worker`)

Duplicate the API service or add another GitHub service with the **same root directory** `wamu-backend`.

1. **Settings → Deploy → Custom Start Command:**

   ```text
   /app/scripts/entrypoint_celery.sh worker-beat
   ```

2. Copy the **same variables** as the API (especially `DATABASE_URL`, `REDIS_URL`, `CELERY_BROKER_URL`, `SECRET_KEY`, `ENVIRONMENT`, mocks, MoMo keys).
3. **Networking:** optional private service (no public domain). Railway still sets `PORT` for the health sidecar in `entrypoint_celery.sh`.

### 5. Verify

```bash
curl -sS "https://YOUR-RAILWAY-DOMAIN.up.railway.app/api/v1/health"
curl -sS "https://YOUR-RAILWAY-DOMAIN.up.railway.app/api/v1/health/database"
curl -sS "https://YOUR-RAILWAY-DOMAIN.up.railway.app/api/v1/health/redis"
```

From repo root (optional):

```bash
./infrastructure/verify_deploy.sh https://YOUR-RAILWAY-DOMAIN.up.railway.app
```

(Adjust script URL arg if it defaults to localhost.)

### 6. Flutter / Play build

```bash
cd wamu-mobile
flutter build apk --release \
  --dart-define=API_BASE_URL=https://YOUR-RAILWAY-DOMAIN.up.railway.app
```

## Environment variables

Use **`ENVIRONMENT=staging`** for the first Railway deploy (mock OTP + mock payments allowed). Template: [`env.reference.example`](./env.reference.example).

Minimum for a working demo:

- `ENVIRONMENT=staging`, `DEBUG=false`
- `SECRET_KEY` (≥32 chars, not a placeholder)
- `DATABASE_URL`, `REDIS_URL`, `CELERY_BROKER_URL`
- `OTP_MOCK_MODE=true`, `PAYMENT_MOCK_AUTO_SUCCESS=true` (until live rails)
- `PUBLIC_API_BASE=https://….up.railway.app`
- `S3_ENABLED=false` (default)
- `REALTIME_USE_REDIS=true`
- `CORS_ORIGINS` — include any web admin origins you use

When you turn on live MoMo on Railway, use **MTN sandbox first** — [`documentation/MTN_RAILWAY_LAUNCH.md`](../../documentation/MTN_RAILWAY_LAUNCH.md). Defer Airtel until you have stable server egress (Hetzner/GCP or Railway Pro static IPs); see [`AIRTEL_PORTAL_CHECKLIST.md`](../../documentation/AIRTEL_PORTAL_CHECKLIST.md) only then.

## Custom domain (`api.wamu.ug`)

1. Railway **wamu-api** → **Networking** → **Custom Domain** → `api.wamu.ug`.
2. Add the CNAME Railway shows at your DNS host.
3. Update `PUBLIC_API_BASE=https://api.wamu.ug` and redeploy API + worker.

## MoMo on Railway (MTN first)

- **Ship with mocks:** `PAYMENT_MOCK_AUTO_SUCCESS=true` — Flutter cart uses **MTN MoMo** by default; Airtel is hidden unless you build with `MOMO_AIRTEL_ENABLED=true`.
- **Live sandbox:** MTN callbacks to `{PUBLIC_API_BASE}/api/v1/payments/webhooks/MTN`. Callback **host** for sandbox API user provisioning is the Railway hostname only (see `scripts/provision_mtn_sandbox.py`). Full steps: [`documentation/MTN_RAILWAY_LAUNCH.md`](../../documentation/MTN_RAILWAY_LAUNCH.md).
- **Airtel:** not recommended on Railway trial (egress IP allowlist). Keep Airtel docs for later on VPS/GCP.

## Cost expectations

Rough order of magnitude on Railway ([usage pricing](https://docs.railway.com/pricing/plans)):

- **Trial:** $5 one-time — enough for a short beta if you keep **one** small API + **one** worker + tiny DBs; burn rate rises with RAM/CPU uptime.
- **After trial:** Free tier includes **$1/month** credit (very tight for API + worker + Postgres + Redis). **Hobby ($5/mo)** is the realistic floor for this stack.
- **Hetzner CX23 (~€4/mo)** remains cheaper for **always-on** API + worker + Postgres + Redis + MinIO on one VM — see `infrastructure/hetzner/README.md`.

## CLI (optional)

```bash
npm i -g @railway/cli   # or brew install railway
railway login
railway link
```

Set variables and deploy from CI; dashboard flow above is enough for first ship.

## Related docs

- Local staging: [`documentation/DEPLOY.md`](../../documentation/DEPLOY.md)
- Long-term GCP: `infrastructure/gcp/`
- VPS alternative: `infrastructure/hetzner/`
