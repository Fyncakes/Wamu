#!/usr/bin/env bash
# Deploy Wamu stack to an already-provisioned Hetzner VPS over SSH.
# Usage:
#   HETZNER_HOST=root@x.x.x.x ./infrastructure/hetzner/deploy.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOST="${HETZNER_HOST:?Set HETZNER_HOST=root@IP}"
REMOTE_DIR="${HETZNER_REMOTE_DIR:-/opt/wamu}"
DOMAIN="${WAMU_DOMAIN:-}"

if [[ ! -f "$ROOT/infrastructure/hetzner/.env.hetzner" ]]; then
  echo "Missing infrastructure/hetzner/.env.hetzner"
  exit 1
fi

echo "==> Ensuring Docker on $HOST"
ssh -o StrictHostKeyChecking=accept-new "$HOST" bash -s <<'REMOTE'
set -euo pipefail
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
fi
mkdir -p /opt/wamu
REMOTE

echo "==> Syncing repo (backend + hetzner infra)"
rsync -az --delete \
  --exclude '.git' \
  --exclude '**/__pycache__' \
  --exclude '**/.venv' \
  --exclude 'wamu-mobile' \
  --exclude '**/node_modules' \
  "$ROOT/wamu-backend/" "$HOST:$REMOTE_DIR/wamu-backend/"
rsync -az \
  "$ROOT/infrastructure/hetzner/" "$HOST:$REMOTE_DIR/infrastructure/hetzner/"

# Fix compose build context path: compose lives under infrastructure/hetzner,
# context ../../wamu-backend from that dir on remote becomes /opt/wamu/wamu-backend
ssh "$HOST" bash -s <<REMOTE
set -euo pipefail
cd $REMOTE_DIR/infrastructure/hetzner
if [[ -n "$DOMAIN" ]]; then
  export WAMU_DOMAIN="$DOMAIN"
  # Caddyfile uses {\$WAMU_DOMAIN:...}; pass via env file for caddy container
  grep -q '^WAMU_DOMAIN=' .env.hetzner 2>/dev/null || echo "WAMU_DOMAIN=$DOMAIN" >> .env.hetzner
fi
docker compose --env-file .env.hetzner up -d --build
docker compose --env-file .env.hetzner ps
REMOTE

echo "==> Done. Set PUBLIC_API_BASE in .env.hetzner to https://\$DOMAIN then redeploy caddy/api."
