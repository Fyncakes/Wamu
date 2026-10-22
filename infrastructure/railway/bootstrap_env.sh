#!/usr/bin/env bash
# Generate staging secrets for Railway (mock OTP + mock payments, MTN-ready).
# Usage: ./infrastructure/railway/bootstrap_env.sh
# Output: infrastructure/railway/.env.railway.generated (gitignored) + stdout for paste into Railway.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/infrastructure/railway/.env.railway.generated"

SECRET_KEY="$(python3 -c "import secrets; print(secrets.token_urlsafe(48))")"
WEBHOOK_SECRET="$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")"

cat >"$OUT" <<EOF
# Generated $(date -u +"%Y-%m-%dT%H:%M:%SZ") — paste into Railway (api + worker). Set PUBLIC_API_BASE after domain.
ENVIRONMENT=staging
DEBUG=false
SECRET_KEY=$SECRET_KEY

OTP_MOCK_MODE=true
PAYMENT_MOCK_AUTO_SUCCESS=true
PAYMENT_WEBHOOK_SECRET=$WEBHOOK_SECRET
PLATFORM_FEE_BPS=250
PROVIDER_FEE_BPS=150
PAYOUT_AUTO_EXECUTE=false
SUSPENSE_ALERT_THRESHOLD_MINOR=100000

PUBLIC_API_BASE=https://REPLACE_AFTER_RAILWAY_DOMAIN
PUBLIC_MEDIA_BASE=https://REPLACE_AFTER_RAILWAY_DOMAIN

S3_ENABLED=false
REALTIME_USE_REDIS=true
CORS_ORIGINS=["https://REPLACE_AFTER_RAILWAY_DOMAIN"]

STUN_URLS=stun:stun.l.google.com:19302,stun:stun1.l.google.com:19302

# MTN sandbox — fill when leaving payment mock (see documentation/MTN_RAILWAY_LAUNCH.md)
# MTN_SUBSCRIPTION_KEY=
# MTN_API_USER=
# MTN_API_KEY=
# MTN_WEBHOOK_SECRET=
# MTN_BASE_URL=https://sandbox.momodeveloper.mtn.com
# MTN_TARGET_ENVIRONMENT=sandbox

# DATABASE_URL=postgresql+asyncpg://…  # from Postgres plugin
# REDIS_URL=…                          # from Redis plugin
# CELERY_BROKER_URL=…/1                # same host as REDIS, DB index 1
EOF

echo "[wamu] wrote $OUT"
echo ""
echo "--- Copy below into Railway → Variables (both wamu-api and wamu-worker) ---"
grep -v '^#' "$OUT" | grep -v '^$' || true
echo "---"
echo "Then set DATABASE_URL (postgresql+asyncpg://…), REDIS_URL, CELERY_BROKER_URL from plugins."
