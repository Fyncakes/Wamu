#!/usr/bin/env bash
# Stable phone demo over phone hotspot (no flaky public tunnel).
#
# 1) On the PHONE: turn on Mobile hotspot
# 2) On the PC: connect Wi‑Fi to that hotspot
# 3) Run:  ./infrastructure/phone_hotspot_demo.sh
#
# Then on the phone:
#   • Refreshable app (recommended for demos): open http://PC_IP:8000
#     After code changes: ./infrastructure/phone_demo_rebuild_web.sh → reload page
#   • Native APK: install http://PC_IP:8088/wamu-phone.apk (OTP 123456)
#     UI code changes need a new APK build (refresh will NOT update an APK)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
LOG_DIR="$DIST/demo-logs"
PID_DIR="$DIST/demo-pids"
JAVA_HOME_DEFAULT="$ROOT/.tools/jdk-17.0.20.1+1"

mkdir -p "$DIST" "$LOG_DIR" "$PID_DIR" "$ROOT/wamu-backend/media_uploads"

export JAVA_HOME="${JAVA_HOME:-$JAVA_HOME_DEFAULT}"
export PATH="$JAVA_HOME/bin:${HOME}/flutter/bin:$PATH"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"

LAN="$(hostname -I | awk '{print $1}')"
if [[ -z "$LAN" ]]; then
  echo "[demo] no LAN IP — connect the PC to the phone hotspot first" >&2
  exit 1
fi

echo "[demo] PC LAN IP: $LAN"
echo "[demo] ensuring API + Flutter web…"
if ! curl -sf -m 2 http://127.0.0.1:8000/api/v1/health >/dev/null 2>&1; then
  (
    cd "$ROOT/wamu-backend"
    nohup .venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload \
      >"$LOG_DIR/api.log" 2>&1 &
    echo $! >"$PID_DIR/api.pid"
  )
  for i in $(seq 1 40); do
    curl -sf -m 2 http://127.0.0.1:8000/api/v1/health >/dev/null 2>&1 && break
    sleep 0.5
  done
fi

if [[ ! -f "$DIST/web/index.html" ]]; then
  "$ROOT/infrastructure/phone_demo_rebuild_web.sh"
else
  # ensure mount sees web
  touch "$ROOT/wamu-backend/app/main.py"
  sleep 1
fi

# APK download server
if ! ss -tln | grep -q ':8088'; then
  (
    cd "$DIST"
    nohup python3 -m http.server 8088 --bind 0.0.0.0 >"$LOG_DIR/apk-http.log" 2>&1 &
    echo $! >"$PID_DIR/apk-http.pid"
  )
fi

echo "[demo] building native arm64 APK for http://$LAN:8000 …"
API_HOST="$LAN" "$ROOT/infrastructure/build_phone_apk.sh"

echo "http://$LAN:8000" >"$DIST/DEMO_URL.txt"
echo "http://$LAN:8000/api/v1" >"$DIST/API_URL.txt"

cat >"$DIST/PHONE_LOGIN.md" <<EOF
# Wamu on phone (PC as server — hotspot)

PC IP: **$LAN**

## A) Refreshable demo (recommended)

1. Phone Chrome → **http://${LAN}:8000**
2. OTP **123456**
3. After UI code changes on PC:
   \`./infrastructure/phone_demo_rebuild_web.sh\`
   then **reload** Chrome on the phone.

Tip: Chrome ⋮ → “Add to Home screen” so it feels like an installed app.

## B) Native APK

1. Download **http://${LAN}:8088/wamu-phone.apk**
2. Install → OTP **123456**
3. Note: refreshing the APK does **not** pull new UI — rebuild the APK for code changes.

## Setup reminder

Phone hotspot ON → PC joined to that hotspot → then re-run this script if the PC IP changes.
EOF

echo
echo "============================================"
echo "  PC is the server at $LAN"
echo "  Refreshable app:  http://$LAN:8000"
echo "  Download APK:     http://$LAN:8088/wamu-phone.apk"
echo "  OTP: 123456"
echo "============================================"
curl -sf "http://127.0.0.1:8000/api/v1/health"; echo
