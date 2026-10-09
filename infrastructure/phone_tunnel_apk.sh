#!/usr/bin/env bash
# Expose local API + rebuild phone APK (bypasses Wi‑Fi isolation).
# Usage (from repo root): ./infrastructure/phone_tunnel_apk.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JAVA_HOME="${JAVA_HOME:-$ROOT/.tools/jdk-17.0.20.1+1}"
export JAVA_HOME PATH="$JAVA_HOME/bin:$HOME/flutter/bin:$HOME/Android/Sdk/platform-tools:$PATH"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"

if ! curl -sf -m 3 http://127.0.0.1:8000/api/v1/health >/dev/null; then
  echo "[wamu] start API first: cd wamu-backend && .venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000"
  exit 1
fi

pkill -f 'nokey@localhost.run' 2>/dev/null || true
sleep 1
LOG=/tmp/wamu_tunnel_$$.log
ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -R 80:localhost:8000 nokey@localhost.run >"$LOG" 2>&1 &
SSH_PID=$!
echo "[wamu] waiting for tunnel URL…"
URL=""
for i in $(seq 1 40); do
  URL=$(grep -oE 'https://[a-z0-9]+\.lhr\.life' "$LOG" | head -1 || true)
  if [[ -n "$URL" ]]; then break; fi
  sleep 1
done
if [[ -z "$URL" ]]; then
  echo "[wamu] tunnel failed — see $LOG" >&2
  kill "$SSH_PID" 2>/dev/null || true
  exit 1
fi
echo "[wamu] tunnel: $URL"
curl -sf -m 20 "$URL/api/v1/health" >/dev/null

API_BASE_URL="$URL/api/v1" "$ROOT/infrastructure/build_phone_apk.sh"
LAN=$(hostname -I | awk '{print $1}')
echo
echo "[wamu] APK ready: $ROOT/dist/wamu-phone.apk (arm64)"
echo "[wamu] Download (same Wi‑Fi): http://$LAN:8088/wamu-phone.apk"
echo "[wamu] Or open health on phone: $URL/api/v1/health"
echo "[wamu] OTP: 123456 — keep this terminal open (tunnel pid $SSH_PID)"
wait "$SSH_PID"
