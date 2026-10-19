#!/usr/bin/env bash
# Deploy Celery worker + beat as always-on Cloud Run services.
#
# Needs --no-cpu-throttling and min-instances=1 so Celery keeps consuming.
# Beat is capped at 1 replica.
#
# Usage: ./infrastructure/gcp/deploy_worker.sh
# Prereq: deploy_api.sh (image :latest pushed)

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

need_cmd gcloud
load_env
gcloud_cfg

SQL_CONN="$(sql_connection_name)"
LATEST_IMAGE="${IMAGE}:latest"

VPC_FLAGS=()
if [[ "$REDIS_MODE" == "memorystore" ]]; then
  VPC_FLAGS+=(
    --vpc-connector="$VPC_CONNECTOR"
    --vpc-egress=private-ranges-only
  )
fi

PUBLIC_API_BASE="${PUBLIC_API_BASE:-}"
OTP_MOCK_MODE="${OTP_MOCK_MODE:-true}"
PAYMENT_MOCK_AUTO_SUCCESS="${PAYMENT_MOCK_AUTO_SUCCESS:-true}"
PAYOUT_AUTO_EXECUTE="${PAYOUT_AUTO_EXECUTE:-true}"

ENV_VARS=(
  "ENVIRONMENT=${WAMU_ENVIRONMENT}"
  "DEBUG=false"
  "APP_NAME=WAMU"
  "OTP_MOCK_MODE=${OTP_MOCK_MODE}"
  "PAYMENT_MOCK_AUTO_SUCCESS=${PAYMENT_MOCK_AUTO_SUCCESS}"
  "PAYOUT_AUTO_EXECUTE=${PAYOUT_AUTO_EXECUTE}"
  "PUBLIC_API_BASE=${PUBLIC_API_BASE}"
  "S3_ENABLED=false"
  "REALTIME_USE_REDIS=true"
  "PORT=8080"
)
ENV_JOINED="$(IFS=,; echo "${ENV_VARS[*]}")"

SECRETS=(
  "SECRET_KEY=wamu-secret-key:latest"
  "PAYMENT_WEBHOOK_SECRET=wamu-payment-webhook-secret:latest"
  "DATABASE_URL=wamu-database-url:latest"
  "REDIS_URL=wamu-redis-url:latest"
  "CELERY_BROKER_URL=wamu-celery-broker-url:latest"
)
SECRETS_JOINED="$(IFS=,; echo "${SECRETS[*]}")"

deploy_celery() {
  local name="$1"
  local role="$2"
  echo "==> Deploy ${name} (celery ${role})"
  gcloud run deploy "$name" \
    --image="$LATEST_IMAGE" \
    --region="$GCP_REGION" \
    --platform=managed \
    --no-allow-unauthenticated \
    --port=8080 \
    --cpu=1 \
    --memory=512Mi \
    --no-cpu-throttling \
    --min-instances=1 \
    --max-instances=1 \
    --timeout=3600 \
    --add-cloudsql-instances="$SQL_CONN" \
    --set-env-vars="$ENV_JOINED" \
    --set-secrets="$SECRETS_JOINED" \
    --command=/app/scripts/entrypoint_celery.sh \
    --args="$role" \
    "${VPC_FLAGS[@]}" \
    --quiet
}

deploy_celery "$CLOUD_RUN_WORKER" worker
deploy_celery "$CLOUD_RUN_BEAT" beat

echo ""
echo "Worker + beat deployed (min instances = 1 each — billable)."
echo "Logs: gcloud run services logs read ${CLOUD_RUN_WORKER} --region=${GCP_REGION} --limit=50"
