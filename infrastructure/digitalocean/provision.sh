#!/usr/bin/env bash
# Create a DigitalOcean Droplet for Wamu (requires doctl + DO API token).
# https://docs.digitalocean.com/reference/doctl/
#
#   doctl auth init
#   ./infrastructure/digitalocean/provision.sh
set -euo pipefail

NAME="${DO_DROPLET_NAME:-wamu-api}"
REGION="${DO_REGION:-lon1}"
SIZE="${DO_SIZE:-s-1vcpu-2gb}"
IMAGE="${DO_IMAGE:-ubuntu-24-04-x64}"
SSH_KEY_NAME="${DO_SSH_KEY_NAME:-wamu-laptop}"

if ! command -v doctl >/dev/null 2>&1; then
  echo "Install doctl: https://docs.digitalocean.com/reference/doctl/how-to/install/"
  echo "Or create a Droplet manually in the control panel (Ubuntu 24.04, 2GB, SSH key)."
  exit 1
fi

PUBKEY="${SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"
if [[ ! -f "$PUBKEY" ]]; then
  echo "Missing SSH public key at $PUBKEY"
  exit 1
fi

if ! doctl compute ssh-key list --format Name --no-header | grep -qx "$SSH_KEY_NAME"; then
  doctl compute ssh-key create "$SSH_KEY_NAME" --public-key-file "$PUBKEY"
fi

KEY_ID="$(doctl compute ssh-key list --format ID,Name --no-header | awk -v n="$SSH_KEY_NAME" '$2==n {print $1}')"

if doctl compute droplet list --format Name --no-header | grep -qx "$NAME"; then
  echo "Droplet $NAME already exists"
else
  doctl compute droplet create "$NAME" \
    --region "$REGION" \
    --size "$SIZE" \
    --image "$IMAGE" \
    --ssh-keys "$KEY_ID" \
    --enable-ipv6 \
    --tag-names wamu,api
fi

IP="$(doctl compute droplet get "$NAME" --format PublicIPv4 --no-header)"
echo "DROPLET_IP=$IP"
echo "DO_HOST=root@$IP"
echo "Next: ./infrastructure/digitalocean/bootstrap_env.sh && DO_HOST=root@$IP ./infrastructure/digitalocean/deploy.sh"
