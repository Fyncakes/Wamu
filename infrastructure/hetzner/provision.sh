#!/usr/bin/env bash
# Provision Hetzner CX23 + firewall via hcloud CLI.
# Prerequisites: hcloud context authenticated, SSH public key registered.
set -euo pipefail

NAME="${HETZNER_SERVER_NAME:-wamu-api}"
LOCATION="${HETZNER_LOCATION:-fsn1}"
TYPE="${HETZNER_TYPE:-cx23}"
IMAGE="${HETZNER_IMAGE:-ubuntu-24.04}"
SSH_KEY_NAME="${HETZNER_SSH_KEY_NAME:-wamu-laptop}"

if ! command -v hcloud >/dev/null 2>&1; then
  echo "Install hcloud first: https://github.com/hetznercloud/cli"
  exit 1
fi

PUBKEY="${SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"
if [[ ! -f "$PUBKEY" ]]; then
  echo "Missing SSH public key at $PUBKEY"
  exit 1
fi

if ! hcloud ssh-key describe "$SSH_KEY_NAME" >/dev/null 2>&1; then
  hcloud ssh-key create --name "$SSH_KEY_NAME" --public-key-from-file "$PUBKEY"
fi

if ! hcloud firewall describe wamu-web >/dev/null 2>&1; then
  hcloud firewall create --name wamu-web
  hcloud firewall add-rule wamu-web --direction in --protocol tcp --port 22 --source-ips 0.0.0.0/0 --source-ips ::/0
  hcloud firewall add-rule wamu-web --direction in --protocol tcp --port 80 --source-ips 0.0.0.0/0 --source-ips ::/0
  hcloud firewall add-rule wamu-web --direction in --protocol tcp --port 443 --source-ips 0.0.0.0/0 --source-ips ::/0
  hcloud firewall add-rule wamu-web --direction in --protocol icmp --source-ips 0.0.0.0/0 --source-ips ::/0
fi

if hcloud server describe "$NAME" >/dev/null 2>&1; then
  echo "Server $NAME already exists"
else
  hcloud server create \
    --name "$NAME" \
    --type "$TYPE" \
    --image "$IMAGE" \
    --location "$LOCATION" \
    --ssh-key "$SSH_KEY_NAME" \
    --firewall wamu-web \
    --label app=wamu
fi

IP="$(hcloud server ip "$NAME")"
echo "SERVER_IP=$IP"
echo "ssh root@$IP"
