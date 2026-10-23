#!/usr/bin/env bash
# Generate .env.do for DigitalOcean deploy (local file — gitignored).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/infrastructure/digitalocean/.env.do.generated"
TARGET="$ROOT/infrastructure/digitalocean/.env.do"

SECRET_KEY="$(python3 -c "import secrets; print(secrets.token_urlsafe(48))")"
WEBHOOK_SECRET="$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")"
POSTGRES_PASSWORD="$(python3 -c "import secrets; print(secrets.token_urlsafe(24))")"
S3_SECRET="$(python3 -c "import secrets; print(secrets.token_urlsafe(24))")"

cat >"$OUT" <<EOF
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
PUBLIC_API_BASE=https://REPLACE_AFTER_DNS_OR_IP
PUBLIC_MEDIA_BASE=https://REPLACE_AFTER_DNS_OR_IP
CORS_ORIGINS=["https://wamu.ug","https://admin.wamu.ug"]
REALTIME_USE_REDIS=true
PRESENCE_TTL_SECONDS=90
STUN_URLS=stun:stun.l.google.com:19302,stun:stun1.l.google.com:19302
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
S3_ACCESS_KEY=wamuadmin
S3_SECRET_KEY=$S3_SECRET
S3_BUCKET=wamu-media
WAMU_DOMAIN=api.wamu.ug
EOF

cp "$OUT" "$TARGET"
echo "[wamu] wrote $OUT and $TARGET"
echo "After droplet + DNS: set PUBLIC_API_BASE / PUBLIC_MEDIA_BASE / WAMU_DOMAIN, then deploy."
