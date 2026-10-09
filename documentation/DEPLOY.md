# Wamu — Deploy (staging)

One path from a clean machine to a healthy staging API. Product features stop here; this is the ship gate.

## Prerequisites

- Docker + Docker Compose v2 (your user must be in the `docker` group — `groups` should list `docker`)
- Ports free: `5432`, `6379`, `8000`, `9000`, `9001`

If `docker ps` says permission denied: `sudo usermod -aG docker "$USER"`, then log out/in.

## Bring up staging (recommended)

```bash
chmod +x infrastructure/staging_up.sh infrastructure/staging_down.sh infrastructure/verify_deploy.sh
./infrastructure/staging_up.sh
./infrastructure/verify_deploy.sh
```

That script:

1. Copies `infrastructure/.env.staging.example` → `.env.staging` if missing (mock OTP + mock payments on)
2. Builds and starts Postgres, Redis, MinIO, API, Celery worker, beat
3. Waits until `GET /api/v1/health` succeeds
4. Prints database / redis / rails health snippets
5. Optionally runs a mock payment dry-run when `wamu-backend/.venv` exists

Manual equivalent:

```bash
cp infrastructure/.env.staging.example infrastructure/.env.staging
docker compose -f infrastructure/docker-compose.staging.yml \
  --env-file infrastructure/.env.staging up -d --build
curl -s http://127.0.0.1:8000/api/v1/health
```

API container entrypoint: **Alembic `upgrade head` → bootstrap seed → uvicorn**.

## Health checks

| Endpoint | Expect |
|----------|--------|
| `/api/v1/health` | `ok` |
| `/api/v1/health/database` | connected |
| `/api/v1/health/redis` | connected |
| `/api/v1/health/rails` | mock or live rail status |

Optional readiness script (from `wamu-backend`):

```bash
python -m scripts.staging_readiness --url http://127.0.0.1:8000
```

## Migrations (greenfield-safe)

Chain: `0001_initial` (`create_all`) → `0002`…`0012_order_disputes`. Revisions after `0001` are **idempotent** (skip columns/tables already present from current models). Empty DB + `alembic upgrade head` must reach `0012_order_disputes`.

**Proof (empty SQLite):** `DATABASE_URL=sqlite+aiosqlite:////tmp/wamu_alembic_proof.db python -m alembic upgrade head` → `0012_order_disputes`; second upgrade is a no-op. Staging API uses the same chain against Postgres via `entrypoint.sh`.

```bash
# inside API container or local venv with DATABASE_URL set
python -m alembic upgrade head
python -m alembic current
```

## Point the Flutter app at staging

Use `http://127.0.0.1:8000` (or your LAN IP) as the API base. Login uses mock OTP when `OTP_MOCK_MODE=true`.

## Real MoMo / Firebase (later)

Edit `infrastructure/.env.staging`:

- Set `PAYMENT_MOCK_AUTO_SUCCESS=false`
- Fill `MTN_*` / `AIRTEL_*` sandbox keys
- Set `FCM_SERVER_KEY` when push is live
- Restart: `docker compose -f infrastructure/docker-compose.staging.yml --env-file infrastructure/.env.staging up -d`

See `documentation/PAYMENTS_STAGING.md`, `documentation/PUSH_NOTIFICATIONS.md`, `documentation/WEBRTC_TURN.md`.

## Local HTTPS (optional, no paid domain)

Self-signed Caddy in front of local compose for LAN phones:

```bash
./infrastructure/certs/generate_self_signed.sh
docker compose -f infrastructure/docker-compose.yml \
  -f infrastructure/docker-compose.https.yml up -d
# Phone: https://<PC_IP>:8443/connect  (trust the cert once)
```

Mock OTP path stays `123456` until Africa’s Talking keys are set. Live OTP / MoMo / FCM still require your secrets (see below).

## Production (not this compose file)

Use `.env.production.example` as the contract. Production refuses DEBUG, OTP mocks, payment mocks, CORS `*`, and weak secrets. Do **not** reuse staging defaults.

## Tear down

```bash
./infrastructure/staging_down.sh
# wipe data: ./infrastructure/staging_down.sh -v
```

## Without Docker (local API smoke)

If Docker is not available yet (`docker` group empty / permission denied), prove the money path against local uvicorn:

```bash
# terminal A — fixed script (SQLite + mock)
./wamu-backend/scripts/run_local.sh

# terminal B — full smoke
./infrastructure/verify_deploy.sh http://127.0.0.1:8000
```

Expect `deploy smoke passed` with payment `SUCCESS` / order `CONFIRMED`, then full `smoke_commerce_loop` (set `SKIP_COMMERCE_SMOKE=1` to skip the long loop).

Production fail-closed gate (no server needed):

```bash
cd wamu-backend && python -m scripts.check_production_config
```

Then enable Docker (`sudo usermod -aG docker "$USER"`, log out/in) and run `./infrastructure/staging_up.sh` for Postgres/Redis/MinIO.
