#!/usr/bin/env bash
# Tear down Wamu staging stack.
# From repo root:
#   ./infrastructure/staging_down.sh          # keep volumes
#   ./infrastructure/staging_down.sh -v      # wipe Postgres/MinIO data
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/infrastructure"

ENV_FILE=.env.staging
if [[ ! -f "$ENV_FILE" ]]; then
  ENV_FILE=.env.staging.example
fi

echo "[wamu] docker compose down…"
docker compose -f docker-compose.staging.yml --env-file "$ENV_FILE" down "$@"
echo "[wamu] staging stopped."
