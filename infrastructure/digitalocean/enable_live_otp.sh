#!/usr/bin/env bash
# Flip login OTP from mock to Africa's Talking SMS in infrastructure/digitalocean/.env.do
# Usage:
#   export AFRICASTALKING_USERNAME=...
#   export AFRICASTALKING_API_KEY=...
#   export AFRICASTALKING_SENDER_ID=WAMU   # optional
#   ./infrastructure/digitalocean/enable_live_otp.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$ROOT/infrastructure/digitalocean/.env.do"

USER_NAME="${AFRICASTALKING_USERNAME:-}"
API_KEY="${AFRICASTALKING_API_KEY:-}"
SENDER="${AFRICASTALKING_SENDER_ID:-WAMU}"

if [[ -z "$USER_NAME" || -z "$API_KEY" ]]; then
  echo "Set AFRICASTALKING_USERNAME and AFRICASTALKING_API_KEY first." >&2
  echo "See documentation/LIVE_USER_OTP.md" >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE — run ./infrastructure/digitalocean/bootstrap_env.sh first." >&2
  exit 1
fi

upsert() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
  else
    echo "${key}=${val}" >>"$ENV_FILE"
  fi
}

upsert OTP_MOCK_MODE false
upsert AFRICASTALKING_USERNAME "$USER_NAME"
upsert AFRICASTALKING_API_KEY "$API_KEY"
upsert AFRICASTALKING_SENDER_ID "$SENDER"

echo "[wamu] Live login OTP enabled in $ENV_FILE (OTP_MOCK_MODE=false)."
echo "Redeploy: DO_HOST=root@IP ./infrastructure/digitalocean/deploy.sh"
