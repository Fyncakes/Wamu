#!/usr/bin/env bash
# One-time (idempotent) GCP bootstrap for Wamu API.
#
# Creates: APIs, Artifact Registry, Cloud SQL, GCS bucket, Secret Manager secrets,
# optional Memorystore + VPC connector, Cloud Run service accounts permissions.
#
# Usage (from repo root or this dir):
#   cp infrastructure/gcp/env.gcp.example infrastructure/gcp/.env.gcp
#   # edit .env.gcp
#   ./infrastructure/gcp/setup.sh
#
# Requires: gcloud auth login && gcloud auth application-default login
# Billing must be enabled on the project.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

need_cmd gcloud
need_cmd openssl
load_env
gcloud_cfg

echo "==> Enable APIs"
gcloud services enable \
  run.googleapis.com \
  sqladmin.googleapis.com \
  secretmanager.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  compute.googleapis.com \
  vpcaccess.googleapis.com \
  redis.googleapis.com \
  storage.googleapis.com \
  iam.googleapis.com \
  --quiet

echo "==> Artifact Registry (${AR_REPO})"
if ! gcloud artifacts repositories describe "$AR_REPO" --location="$GCP_REGION" &>/dev/null; then
  gcloud artifacts repositories create "$AR_REPO" \
    --repository-format=docker \
    --location="$GCP_REGION" \
    --description="Wamu container images"
fi

PROJECT_NUMBER="$(gcloud projects describe "$GCP_PROJECT_ID" --format='value(projectNumber)')"
CLOUDBUILD_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

echo "==> IAM (Cloud Build → Artifact Registry + Cloud Run)"
gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
  --member="serviceAccount:${CLOUDBUILD_SA}" \
  --role="roles/run.admin" --quiet >/dev/null || true
gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
  --member="serviceAccount:${CLOUDBUILD_SA}" \
  --role="roles/artifactregistry.writer" --quiet >/dev/null || true
gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
  --member="serviceAccount:${CLOUDBUILD_SA}" \
  --role="roles/iam.serviceAccountUser" --quiet >/dev/null || true

echo "==> Cloud SQL Postgres (${SQL_INSTANCE})"
if ! gcloud sql instances describe "$SQL_INSTANCE" &>/dev/null; then
  gcloud sql instances create "$SQL_INSTANCE" \
    --database-version=POSTGRES_16 \
    --tier="${SQL_TIER:-db-f1-micro}" \
    --region="$GCP_REGION" \
    --storage-auto-increase \
    --root-password="$SQL_PASSWORD" \
    --quiet
fi
if ! gcloud sql databases describe "$SQL_DB" --instance="$SQL_INSTANCE" &>/dev/null; then
  gcloud sql databases create "$SQL_DB" --instance="$SQL_INSTANCE"
fi
# App user (ignore if exists)
gcloud sql users create "$SQL_USER" --instance="$SQL_INSTANCE" --password="$SQL_PASSWORD" 2>/dev/null \
  || gcloud sql users set-password "$SQL_USER" --instance="$SQL_INSTANCE" --password="$SQL_PASSWORD"

echo "==> GCS bucket (${GCS_BUCKET})"
if ! gcloud storage buckets describe "gs://${GCS_BUCKET}" &>/dev/null; then
  gcloud storage buckets create "gs://${GCS_BUCKET}" \
    --location="$GCP_REGION" \
    --uniform-bucket-level-access
fi

echo "==> Secret Manager"
upsert_secret() {
  local name="$1" value="$2"
  if gcloud secrets describe "$name" &>/dev/null; then
    printf '%s' "$value" | gcloud secrets versions add "$name" --data-file=-
  else
    printf '%s' "$value" | gcloud secrets create "$name" --data-file=- --replication-policy=automatic
  fi
}

: "${SECRET_KEY:?set SECRET_KEY in .env.gcp}"
: "${PAYMENT_WEBHOOK_SECRET:?set PAYMENT_WEBHOOK_SECRET in .env.gcp}"
: "${SQL_PASSWORD:?}"

upsert_secret wamu-secret-key "$SECRET_KEY"
upsert_secret wamu-payment-webhook-secret "$PAYMENT_WEBHOOK_SECRET"
upsert_secret wamu-sql-password "$SQL_PASSWORD"
upsert_secret wamu-database-url "$(database_url_cloudsql)"

# Grant default compute SA access to secrets + Cloud SQL
for role in roles/secretmanager.secretAccessor roles/cloudsql.client; do
  gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
    --member="serviceAccount:${COMPUTE_SA}" \
    --role="$role" --quiet >/dev/null || true
done

if [[ "$REDIS_MODE" == "memorystore" ]]; then
  echo "==> VPC connector (${VPC_CONNECTOR})"
  NETWORK="${VPC_NETWORK:-default}"
  if ! gcloud compute networks vpc-access connectors describe "$VPC_CONNECTOR" --region="$GCP_REGION" &>/dev/null; then
    gcloud compute networks vpc-access connectors create "$VPC_CONNECTOR" \
      --region="$GCP_REGION" \
      --network="$NETWORK" \
      --range="${VPC_CONNECTOR_RANGE:-10.8.0.0/28}" \
      --min-instances=2 \
      --max-instances=3 \
      --quiet
  fi

  echo "==> Memorystore Redis (${MEMORYSTORE_NAME})"
  if ! gcloud redis instances describe "$MEMORYSTORE_NAME" --region="$GCP_REGION" &>/dev/null; then
    gcloud redis instances create "$MEMORYSTORE_NAME" \
      --size="${MEMORYSTORE_SIZE_GB:-1}" \
      --region="$GCP_REGION" \
      --redis-version=redis_7_0 \
      --network="$NETWORK" \
      --quiet
  fi
  REDIS_HOST="$(gcloud redis instances describe "$MEMORYSTORE_NAME" --region="$GCP_REGION" --format='value(host)')"
  echo "    REDIS_HOST=${REDIS_HOST}"
  upsert_secret wamu-redis-url "redis://${REDIS_HOST}:6379/0"
  upsert_secret wamu-celery-broker-url "redis://${REDIS_HOST}:6379/1"
else
  echo "==> REDIS_MODE=external — ensure REDIS_URL and CELERY_BROKER_URL are set"
  : "${REDIS_URL:?REDIS_URL required when REDIS_MODE=external}"
  : "${CELERY_BROKER_URL:?CELERY_BROKER_URL required when REDIS_MODE=external}"
  upsert_secret wamu-redis-url "$REDIS_URL"
  upsert_secret wamu-celery-broker-url "$CELERY_BROKER_URL"
fi

echo ""
echo "Setup complete."
echo "  Cloud SQL connection: $(sql_connection_name)"
echo "  Next: ./infrastructure/gcp/deploy_api.sh"
echo "  Then: ./infrastructure/gcp/deploy_worker.sh"
