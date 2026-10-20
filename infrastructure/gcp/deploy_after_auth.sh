#!/usr/bin/env bash
# Run after: gcloud auth login && gcloud auth application-default login
# Expects infrastructure/gcp/.env.gcp with REDIS_MODE=external + REDIS_URL + CELERY_BROKER_URL.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
load_env
gcloud_cfg

ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -1)"
if [[ -z "$ACCOUNT" ]]; then
  echo "ERROR: no active gcloud account — run gcloud auth login first" >&2
  exit 1
fi
echo "==> Authenticated as $ACCOUNT"
gcloud config set project "$GCP_PROJECT_ID"

if [[ "${REDIS_MODE:-}" == "external" ]]; then
  if [[ -z "${REDIS_URL:-}" || -z "${CELERY_BROKER_URL:-}" ]]; then
    echo "ERROR: REDIS_MODE=external requires REDIS_URL and CELERY_BROKER_URL in .env.gcp" >&2
    exit 1
  fi
fi

echo "==> Billing check"
if ! gcloud billing projects describe "$GCP_PROJECT_ID" --format='value(billingEnabled)' | grep -qi true; then
  echo "ERROR: billing not enabled on $GCP_PROJECT_ID — open https://console.cloud.google.com/billing" >&2
  exit 1
fi

./infrastructure/gcp/setup.sh
./infrastructure/gcp/deploy_api.sh

URL="$(gcloud run services describe "${CLOUD_RUN_API}" --region="$GCP_REGION" --format='value(status.url)')"
echo "==> API URL: $URL"
# Persist PUBLIC_API_BASE for next deploys / workers
ENV_FILE="$(cd "$(dirname "$0")" && pwd)/.env.gcp"
if grep -q '^PUBLIC_API_BASE=' "$ENV_FILE"; then
  sed -i "s|^PUBLIC_API_BASE=.*|PUBLIC_API_BASE=${URL}|" "$ENV_FILE"
else
  echo "PUBLIC_API_BASE=${URL}" >> "$ENV_FILE"
fi
# Reload and redeploy so the service sees PUBLIC_API_BASE
load_env
./infrastructure/gcp/deploy_api.sh
./infrastructure/gcp/deploy_worker.sh

echo "==> Smoke"
curl -sfS "$URL/api/v1/health" | python3 -m json.tool || curl -sfS "$URL/api/v1/health"
if [[ -x ./infrastructure/verify_deploy.sh ]]; then
  ./infrastructure/verify_deploy.sh "$URL" || true
fi
echo "DONE url=$URL"
echo "$URL" > /tmp/wamu_cloud_run_url.txt
