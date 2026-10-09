#!/usr/bin/env bash
# Generate a self-signed cert for LAN HTTPS (docker-compose.https.yml).
# Usage: ./infrastructure/certs/generate_self_signed.sh [LAN_IP]
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
IP="${1:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
IP="${IP:-127.0.0.1}"

mkdir -p "$DIR"
openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
  -keyout "$DIR/wamu-key.pem" \
  -out "$DIR/wamu.pem" \
  -subj "/CN=wamu-local/O=WAMU" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:${IP}"

chmod 600 "$DIR/wamu-key.pem"
echo "[certs] wrote $DIR/wamu.pem (+ key) for IP $IP"
echo "[certs] compose: docker compose -f infrastructure/docker-compose.yml -f infrastructure/docker-compose.https.yml up -d"
echo "[certs] phone URL: https://${IP}:8443/connect"
