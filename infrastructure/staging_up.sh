#!/usr/bin/env bash
# Bring up Wamu staging stack (Postgres + Redis + MinIO + API + worker + beat).
# From repo root:
#   ./infrastructure/staging_up.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/infrastructure"

if ! command -v docker >/dev/null 2>&1; then
  echo "[wamu] docker not found — install Docker Engine + Compose v2" >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "[wamu] cannot talk to Docker daemon." >&2
  echo "  If permission denied: sudo usermod -aG docker \"\$USER\" then log out/in." >&2
  echo "  If sock missing: sudo systemctl start docker" >&2
  exit 1
fi

if [[ ! -f .env.staging ]]; then
  echo "[wamu] creating infrastructure/.env.staging from example (mock-friendly dry-run)"
  cp .env.staging.example .env.staging
fi

echo "[wamu] docker compose up (staging)…"
docker compose -f docker-compose.staging.yml --env-file .env.staging up -d --build "$@"

echo "[wamu] waiting for API health…"
ok=0
for i in $(seq 1 60); do
  if curl -sf http://127.0.0.1:8000/api/v1/health >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 2
done

if [[ "$ok" -ne 1 ]]; then
  echo "[wamu] API did not become healthy — last logs:" >&2
  docker compose -f docker-compose.staging.yml --env-file .env.staging logs --tail=80 api >&2 || true
  exit 1
fi

echo "[wamu] healthy:"
curl -s http://127.0.0.1:8000/api/v1/health
echo
curl -s http://127.0.0.1:8000/api/v1/health/database
echo
curl -s http://127.0.0.1:8000/api/v1/health/redis
echo
curl -s http://127.0.0.1:8000/api/v1/health/rails | head -c 500
echo
echo
echo "[wamu] mock payment dry-run (optional smoke)…"
if [[ -x "$ROOT/wamu-backend/.venv/bin/python" ]]; then
  (cd "$ROOT/wamu-backend" && .venv/bin/python -m scripts.payments_dry_run --base http://127.0.0.1:8000) || \
    echo "[wamu] dry-run skipped/failed — API is up; run manually: python -m scripts.payments_dry_run"
else
  echo "[wamu] no wamu-backend/.venv — skip dry-run; see documentation/DEPLOY.md"
fi
echo
echo "[wamu] staging is up. See documentation/DEPLOY.md"
