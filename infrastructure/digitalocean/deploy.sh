#!/usr/bin/env bash
# Deploy Wamu stack to a DigitalOcean Droplet over SSH.
# Usage:
#   DO_HOST=root@DROPLET_IP ./infrastructure/digitalocean/deploy.sh
# Optional: WAMU_DOMAIN=api.wamu.ug
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOST="${DO_HOST:?Set DO_HOST=root@DROPLET_IP}"
REMOTE_DIR="${DO_REMOTE_DIR:-/opt/wamu}"
DOMAIN="${WAMU_DOMAIN:-}"

ENV_FILE="$ROOT/infrastructure/digitalocean/.env.do"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE — run ./infrastructure/digitalocean/bootstrap_env.sh first"
  exit 1
fi

echo "==> Ensuring Docker on $HOST"
ssh -o StrictHostKeyChecking=accept-new "$HOST" bash -s <<'REMOTE'
set -euo pipefail
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
fi
mkdir -p /opt/wamu/infrastructure/digitalocean
REMOTE

echo "==> Syncing backend + digitalocean infra"
rsync -az --delete \
  --exclude '.git' \
  --exclude '**/__pycache__' \
  --exclude '**/.venv' \
  --exclude 'wamu-mobile' \
  --exclude '**/node_modules' \
  "$ROOT/wamu-backend/" "$HOST:$REMOTE_DIR/wamu-backend/"
rsync -az \
  "$ROOT/infrastructure/digitalocean/" "$HOST:$REMOTE_DIR/infrastructure/digitalocean/"

ssh "$HOST" bash -s <<REMOTE
set -euo pipefail
cd $REMOTE_DIR/infrastructure/digitalocean
if [[ -n "$DOMAIN" ]]; then
  grep -q '^WAMU_DOMAIN=' .env.do 2>/dev/null && sed -i "s|^WAMU_DOMAIN=.*|WAMU_DOMAIN=$DOMAIN|" .env.do || echo "WAMU_DOMAIN=$DOMAIN" >> .env.do
fi
docker compose --env-file .env.do up -d --build
docker compose --env-file .env.do ps
REMOTE

echo "==> Smoke (HTTP on droplet IP if no TLS yet):"
echo "    curl -sS http://DROPLET_IP/api/v1/health  # only if you temporarily expose api — default is Caddy on 443"
echo "    ./infrastructure/verify_deploy.sh https://\$WAMU_DOMAIN"
