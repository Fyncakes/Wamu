#!/usr/bin/env bash
# End-to-end ship smoke against a running API (Docker or local uvicorn).
# From repo root:
#   ./infrastructure/verify_deploy.sh
#   ./infrastructure/verify_deploy.sh http://127.0.0.1:8000
set -euo pipefail

BASE="${1:-http://127.0.0.1:8000}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/wamu-backend/.venv/bin/python"

echo "[wamu] verify against $BASE"

curl -sf "$BASE/api/v1/health" | tee /tmp/wamu_health.json >/dev/null
echo "  health: OK"

curl -sf "$BASE/api/v1/health/database" | tee /tmp/wamu_db.json >/dev/null
grep -q '"status":"ok"' /tmp/wamu_db.json
echo "  database: OK"

# Redis may be degraded (memory fallback) in local runs — fail only on hard error.
curl -sf "$BASE/api/v1/health/redis" | tee /tmp/wamu_redis.json >/dev/null
if grep -q '"status":"error"' /tmp/wamu_redis.json; then
  echo "  redis: ERROR" >&2
  cat /tmp/wamu_redis.json >&2
  exit 1
fi
echo "  redis: $(python3 -c "import json;print(json.load(open('/tmp/wamu_redis.json')).get('status','?'))")"

curl -sf "$BASE/api/v1/health/rails" | tee /tmp/wamu_rails.json >/dev/null
grep -q '"ready_for_mock_dry_run":true' /tmp/wamu_rails.json
echo "  rails mock dry-run: OK"

if [[ -x "$PY" ]]; then
  (cd "$ROOT/wamu-backend" && "$PY" -m scripts.staging_readiness --url "$BASE" --strict) >/tmp/wamu_readiness.json
  echo "  staging_readiness: OK"
  if [[ "${STRICT_LIVE:-0}" == "1" ]]; then
    (cd "$ROOT/wamu-backend" && "$PY" -m scripts.staging_readiness --url "$BASE" --strict-live)
    echo "  staging_readiness --strict-live: OK"
  fi
  (cd "$ROOT/wamu-backend" && "$PY" -m scripts.payments_dry_run --base "$BASE") | tee /tmp/wamu_dry_run.json
  grep -q '"payment_status": "SUCCESS"' /tmp/wamu_dry_run.json
  grep -q '"order_status": "CONFIRMED"' /tmp/wamu_dry_run.json
  echo "  payments_dry_run: OK (SUCCESS / CONFIRMED)"
  if [[ "${SKIP_COMMERCE_SMOKE:-0}" != "1" ]]; then
    (cd "$ROOT/wamu-backend" && "$PY" -m scripts.smoke_commerce_loop --base "$BASE")
    echo "  smoke_commerce_loop: OK"
  else
    echo "  smoke_commerce_loop: skipped (SKIP_COMMERCE_SMOKE=1)"
  fi
else
  echo "  skip python smokes (no wamu-backend/.venv)" >&2
fi

echo
echo "[wamu] deploy smoke passed for $BASE"
