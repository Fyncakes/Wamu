#!/usr/bin/env bash
# Local API without Docker — SQLite + mock OTP/payments (ship smoke when Docker unavailable).
# From repo:  ./wamu-backend/scripts/run_local.sh
# Or:        cd wamu-backend && ./scripts/run_local.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -d .venv ]]; then
  echo "[wamu] create venv first: python3 -m venv .venv && .venv/bin/pip install -r requirements.txt" >&2
  exit 1
fi
# shellcheck disable=SC1091
source .venv/bin/activate

export DATABASE_URL="${DATABASE_URL:-sqlite+aiosqlite:///./wamu_dev.db}"
export OTP_MOCK_MODE="${OTP_MOCK_MODE:-true}"
export PAYMENT_MOCK_AUTO_SUCCESS="${PAYMENT_MOCK_AUTO_SUCCESS:-true}"
export PYTHONPATH=.

echo "[wamu] bootstrap…"
python -m scripts.bootstrap

echo "[wamu] uvicorn on 0.0.0.0:8000 (DATABASE_URL=$DATABASE_URL)"
exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
