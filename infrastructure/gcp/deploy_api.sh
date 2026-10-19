#!/usr/bin/env bash
# Build API image locally (or via Cloud Build) and deploy Cloud Run API.
#
# Usage:
#   ./infrastructure/gcp/deploy_api.sh           # local docker build + push + deploy
#   ./infrastructure/gcp/deploy_api.sh --cloudbuild
#
# After first deploy, copy the service URL into PUBLIC_API_BASE and re-run to
# refresh env (or map a custom domain in Cloud Run).

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

need_cmd gcloud
need_cmd docker
load_env
gcloud_cfg

USE_CLOUDBUILD=0
[[ "${1:-}" == "--cloudbuild" ]] && USE_CLOUDBUILD=1

TAG="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)"
FULL_IMAGE="${IMAGE}:${TAG}"
LATEST_IMAGE="${IMAGE}:latest"
SQL_CONN="$(sql_connection_name)"

if [[ "$USE_CLOUDBUILD" -eq 1 ]]; then
  echo "==> Cloud Build"
  gcloud builds submit "$REPO_ROOT" \
    --config="$GCP_DIR/cloudbuild.yaml" \
    --substitutions="_REGION=${GCP_REGION},_SERVICE=${CLOUD_RUN_API},_AR_REPO=${AR_REPO}"
  FULL_IMAGE="${IMAGE}:latest"
else
  echo "==> Docker build ${FULL_IMAGE}"
  gcloud auth configure-docker "${GCP_REGION}-docker.pkg.dev" --quiet
  docker build -t "$FULL_IMAGE" -t "$LATEST_IMAGE" "$REPO_ROOT/wamu-backend"
  docker push "$FULL_IMAGE"
  docker push "$LATEST_IMAGE"
fi

VPC_FLAGS=()
if [[ "$REDIS_MODE" == "memorystore" ]]; then
  VPC_FLAGS+=(
    --vpc-connector="$VPC_CONNECTOR"
    --vpc-egress=private-ranges-only
  )
fi

PUBLIC_API_BASE="${PUBLIC_API_BASE:-}"
PUBLIC_MEDIA_BASE="${PUBLIC_MEDIA_BASE:-https://storage.googleapis.com/${GCS_BUCKET}}"
CORS_ORIGINS="${CORS_ORIGINS:-[\"*\"]}"
ADMIN_BOOTSTRAP_PHONE="${ADMIN_BOOTSTRAP_PHONE:-+256700000001}"
OTP_MOCK_MODE="${OTP_MOCK_MODE:-true}"
PAYMENT_MOCK_AUTO_SUCCESS="${PAYMENT_MOCK_AUTO_SUCCESS:-true}"
PAYOUT_AUTO_EXECUTE="${PAYOUT_AUTO_EXECUTE:-true}"

# Plain env (no secrets). URLs/passwords come from Secret Manager.
ENV_VARS=(
  "ENVIRONMENT=${WAMU_ENVIRONMENT}"
  "DEBUG=false"
  "APP_NAME=WAMU"
  "OTP_MOCK_MODE=${OTP_MOCK_MODE}"
  "PAYMENT_MOCK_AUTO_SUCCESS=${PAYMENT_MOCK_AUTO_SUCCESS}"
  "PAYOUT_AUTO_EXECUTE=${PAYOUT_AUTO_EXECUTE}"
  "ADMIN_BOOTSTRAP_PHONE=${ADMIN_BOOTSTRAP_PHONE}"
  "PUBLIC_API_BASE=${PUBLIC_API_BASE}"
  "PUBLIC_MEDIA_BASE=${PUBLIC_MEDIA_BASE}"
  "CORS_ORIGINS=${CORS_ORIGINS}"
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

echo "==> Deploy Cloud Run ${CLOUD_RUN_API}"
gcloud run deploy "$CLOUD_RUN_API" \
  --image="$FULL_IMAGE" \
  --region="$GCP_REGION" \
  --platform=managed \
  --allow-unauthenticated \
  --port=8080 \
  --cpu=1 \
  --memory=512Mi \
  --min-instances=0 \
  --max-instances=5 \
  --timeout=300 \
  --add-cloudsql-instances="$SQL_CONN" \
  --set-env-vars="$ENV_JOINED" \
  --set-secrets="$SECRETS_JOINED" \
  "${VPC_FLAGS[@]}" \
  --quiet

SERVICE_URL="$(gcloud run services describe "$CLOUD_RUN_API" --region="$GCP_REGION" --format='value(status.url)')"
echo ""
echo "API deployed: ${SERVICE_URL}"
echo "Health:       ${SERVICE_URL}/api/v1/health"
echo ""
echo "Next:"
echo "  1. Set PUBLIC_API_BASE=${SERVICE_URL} in .env.gcp and re-run this script"
echo "  2. ./infrastructure/gcp/deploy_worker.sh"
echo "  3. curl -s ${SERVICE_URL}/api/v1/health | python3 -m json.tool"
echo "  4. Flutter: flutter run --dart-define=API_BASE_URL=${SERVICE_URL}"
