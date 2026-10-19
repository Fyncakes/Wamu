#!/usr/bin/env bash
# Shared helpers for GCP scripts. Sourced by setup.sh / deploy_*.sh
# shellcheck disable=SC2034

set -euo pipefail

GCP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$GCP_DIR/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$GCP_DIR/.env.gcp}"

die() { echo "ERROR: $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

load_env() {
  [[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE — copy env.gcp.example → .env.gcp and fill values"
  # shellcheck disable=SC1090
  set -a
  # shellcheck disable=SC1091
  source "$ENV_FILE"
  set +a
  : "${GCP_PROJECT_ID:?}"
  : "${GCP_REGION:?}"
  AR_REPO="${AR_REPO:-wamu}"
  SQL_INSTANCE="${SQL_INSTANCE:-wamu-pg}"
  SQL_DB="${SQL_DB:-wamu}"
  SQL_USER="${SQL_USER:-wamu}"
  CLOUD_RUN_API="${CLOUD_RUN_API:-wamu-api}"
  CLOUD_RUN_WORKER="${CLOUD_RUN_WORKER:-wamu-worker}"
  CLOUD_RUN_BEAT="${CLOUD_RUN_BEAT:-wamu-beat}"
  WAMU_ENVIRONMENT="${WAMU_ENVIRONMENT:-staging}"
  REDIS_MODE="${REDIS_MODE:-memorystore}"
  GCS_BUCKET="${GCS_BUCKET:-wamu-media-${GCP_PROJECT_ID}}"
  MEMORYSTORE_NAME="${MEMORYSTORE_NAME:-wamu-redis}"
  VPC_CONNECTOR="${VPC_CONNECTOR:-wamu-vpc-connector}"
  IMAGE="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/${AR_REPO}/api"
}

gcloud_cfg() {
  gcloud config set project "$GCP_PROJECT_ID" --quiet
  gcloud config set run/region "$GCP_REGION" --quiet
}

sql_connection_name() {
  gcloud sql instances describe "$SQL_INSTANCE" --format='value(connectionName)'
}

# asyncpg unix-socket URL for Cloud Run + Cloud SQL Auth
database_url_cloudsql() {
  local conn
  conn="$(sql_connection_name)"
  # Password must be URL-safe; prefer no special chars in SQL_PASSWORD
  echo "postgresql+asyncpg://${SQL_USER}:${SQL_PASSWORD}@/${SQL_DB}?host=/cloudsql/${conn}"
}
