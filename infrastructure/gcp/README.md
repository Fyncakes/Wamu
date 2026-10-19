# Wamu on Google Cloud (Cloud Run)

First production-shaped host for the API so Play Store builds can point at a stable HTTPS URL.

| Piece | Service |
|-------|---------|
| API | Cloud Run `wamu-api` |
| Postgres | Cloud SQL (Postgres 16) |
| Redis / Celery | Memorystore + Serverless VPC connector **or** external Redis (Upstash) |
| Images | Artifact Registry |
| Secrets | Secret Manager |
| Media (later) | GCS bucket (S3-compatible HMAC) |
| Workers | Cloud Run `wamu-worker` + `wamu-beat` (min instances = 1) |

## Prerequisites

1. [Google Cloud project](https://console.cloud.google.com/) with **billing enabled**
2. `gcloud` CLI installed and logged in:
   ```bash
   gcloud auth login
   gcloud auth application-default login
   gcloud components install beta  # if prompted
   ```
3. Docker (for local image build) **or** use `--cloudbuild`
4. Cost awareness: `db-f1-micro` + Memorystore 1GB + 2 always-on workers ≈ tens of USD/month; scale to zero API helps

## Quick path

```bash
cd /path/to/WAMU
cp infrastructure/gcp/env.gcp.example infrastructure/gcp/.env.gcp
```

Edit `.env.gcp`:

- `GCP_PROJECT_ID` — your project id  
- `GCP_REGION` — e.g. `europe-west1` (or `africa-south1` if available for you)  
- `SQL_PASSWORD`, `SECRET_KEY`, `PAYMENT_WEBHOOK_SECRET` — strong random values  
  ```bash
  openssl rand -hex 32   # SECRET_KEY
  openssl rand -hex 24   # PAYMENT_WEBHOOK_SECRET / SQL_PASSWORD base
  ```
- First deploy: keep `OTP_MOCK_MODE=true` and `PAYMENT_MOCK_AUTO_SUCCESS=true` (`WAMU_ENVIRONMENT=staging`)  
- Faster Redis (skip Memorystore): `REDIS_MODE=external` + Upstash URLs

```bash
chmod +x infrastructure/gcp/*.sh
./infrastructure/gcp/setup.sh          # ~10–20 min first time (SQL + Redis)
./infrastructure/gcp/deploy_api.sh     # build + push + Cloud Run API
# copy printed URL into PUBLIC_API_BASE in .env.gcp, then:
./infrastructure/gcp/deploy_api.sh     # refresh PUBLIC_API_BASE
./infrastructure/gcp/deploy_worker.sh  # Celery worker + beat
```

Smoke:

```bash
URL="$(gcloud run services describe wamu-api --region="$GCP_REGION" --format='value(status.url)')"
curl -s "$URL/api/v1/health" | python3 -m json.tool
./infrastructure/verify_deploy.sh "$URL"
```

Point the app:

```bash
cd wamu-mobile
flutter run --dart-define=API_BASE_URL=https://YOUR-SERVICE.run.app
```

## Architecture notes

### Database URL

Cloud Run talks to Cloud SQL over the Auth unix socket. Secret `wamu-database-url` looks like:

```text
postgresql+asyncpg://wamu:PASSWORD@/wamu?host=/cloudsql/PROJECT:REGION:INSTANCE
```

`--add-cloudsql-instances` is set on every Cloud Run service.

### Redis modes

| `REDIS_MODE` | What setup.sh does |
|--------------|--------------------|
| `memorystore` (default) | VPC connector + Memorystore Redis 7 |
| `external` | Stores your `REDIS_URL` / `CELERY_BROKER_URL` in Secret Manager only |

### Workers

Celery cannot scale to zero. Worker and beat use `entrypoint_celery.sh` (background Celery + HTTP `/` health for Cloud Run). They cost while running — pause them when not needed:

```bash
gcloud run services update wamu-worker --min-instances=0 --region=$GCP_REGION
gcloud run services update wamu-beat --min-instances=0 --region=$GCP_REGION
```

### Custom domain

Cloud Run → Manage custom domains → map `api.wamu.ug` → update `PUBLIC_API_BASE` and MTN/Airtel callback URLs.

### Production gate

When ready for real OTP/MoMo:

1. Set `WAMU_ENVIRONMENT=production` in `.env.gcp`
2. `OTP_MOCK_MODE=false`, `PAYMENT_MOCK_AUTO_SUCCESS=false`
3. Fill Africa’s Talking + MTN (and later Airtel) secrets — add via Secret Manager / `--update-secrets`
4. Explicit `CORS_ORIGINS` (no `*`)
5. Re-run `deploy_api.sh` + `deploy_worker.sh`

See `wamu-backend/.env.production.example` and `documentation/PRODUCTION_READINESS.md`.

## Cloud Build (optional CI)

```bash
gcloud builds submit --config infrastructure/gcp/cloudbuild.yaml \
  --substitutions=_REGION=europe-west1,_SERVICE=wamu-api
```

## Tear-down (careful)

```bash
gcloud run services delete wamu-api wamu-worker wamu-beat --region=$GCP_REGION --quiet
gcloud sql instances delete wamu-pg --quiet
gcloud redis instances delete wamu-redis --region=$GCP_REGION --quiet
# secrets, AR images, GCS bucket — delete manually if you want a full wipe
```

## Play Store link

Once health is green on Cloud Run HTTPS:

1. Commit this scaffold  
2. Build a release APK/AAB with `--dart-define=API_BASE_URL=https://…`  
3. Continue track **(3) Android release signing** (keystore + Play Console)
