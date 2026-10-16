#!/usr/bin/env bash
# One control: start Wamu on this PC so friends can use the APK / phone browser.
# Usage:
#   ./start_wamu.sh              # API + public tunnel + watchdog
#   ./start_wamu.sh --rebuild    # also rebuild Flutter web
#   ./start_wamu.sh --apk        # also rebuild shareable APK
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
LOG_DIR="$DIST/demo-logs"
PID_DIR="$DIST/demo-pids"
CF="$ROOT/.tools/cloudflared"
URL_FILE="$DIST/DEMO_URL.txt"
# shellcheck source=infrastructure/demo_access.sh
source "$ROOT/infrastructure/demo_access.sh"
export DEMO_ROOT="$ROOT"

REBUILD=0
BUILD_APK=0
for arg in "$@"; do
  case "$arg" in
    --rebuild) REBUILD=1 ;;
    --apk) BUILD_APK=1 ;;
    -h|--help)
      sed -n '2,8p' "$0"
      exit 0
      ;;
  esac
done

mkdir -p "$DIST" "$LOG_DIR" "$PID_DIR" "$ROOT/wamu-backend/media_uploads"

echo "[wamu] starting…"

# --- API ---
if ! curl -sf -m 2 http://127.0.0.1:8000/api/v1/health >/dev/null 2>&1; then
  if command -v fuser >/dev/null 2>&1; then
    fuser -k 8000/tcp 2>/dev/null || true
  fi
  (
    cd "$ROOT/wamu-backend"
    nohup .venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload \
      >"$LOG_DIR/api.log" 2>&1 &
    echo $! >"$PID_DIR/api.pid"
  )
  for _ in $(seq 1 50); do
    curl -sf -m 2 http://127.0.0.1:8000/api/v1/health >/dev/null 2>&1 && break
    sleep 0.4
  done
fi
curl -sf -m 5 http://127.0.0.1:8000/api/v1/health >/dev/null
echo "[wamu] API OK"

# --- Web UI (same-origin for phone Chrome) ---
if [[ "$REBUILD" -eq 1 ]] || [[ ! -f "$DIST/web/index.html" ]]; then
  echo "[wamu] building Flutter web…"
  "$ROOT/infrastructure/phone_demo_rebuild_web.sh"
fi

# --- APK HTTP share on :8088 ---
if ! ss -tln 2>/dev/null | grep -q ':8088'; then
  (
    cd "$DIST"
    nohup python3 -m http.server 8088 --bind 0.0.0.0 >"$LOG_DIR/apk-http.log" 2>&1 &
    echo $! >"$PID_DIR/apk-http.pid"
  )
fi

# --- Optional APK rebuild ---
if [[ "$BUILD_APK" -eq 1 ]] || [[ ! -f "$DIST/wamu-phone.apk" ]]; then
  echo "[wamu] building phone APK…"
  "$ROOT/infrastructure/build_phone_apk.sh"
fi

# --- Public tunnel ---
if [[ -f "$PID_DIR/tunnel.pid" ]]; then
  kill "$(cat "$PID_DIR/tunnel.pid")" 2>/dev/null || true
  rm -f "$PID_DIR/tunnel.pid"
fi
pkill -f "$CF tunnel --url" 2>/dev/null || true
sleep 1

URL=""
if [[ -f "$DIST/NAMED_TUNNEL_CONFIG.txt" && -f "$DIST/NAMED_TUNNEL_URL.txt" ]]; then
  NAMED_CFG=$(cat "$DIST/NAMED_TUNNEL_CONFIG.txt")
  NAMED_URL=$(cat "$DIST/NAMED_TUNNEL_URL.txt")
  if [[ -f "$NAMED_CFG" && -x "$CF" ]]; then
    echo "[wamu] named tunnel → $NAMED_URL"
    nohup "$CF" tunnel --config "$NAMED_CFG" run --no-autoupdate >"$LOG_DIR/tunnel.log" 2>&1 &
    echo $! >"$PID_DIR/tunnel.pid"
    for _ in $(seq 1 30); do
      if curl -sf -m 12 "$NAMED_URL/api/v1/health" >/dev/null 2>&1; then
        URL="$NAMED_URL"
        break
      fi
      sleep 1
    done
  fi
fi

if [[ -z "$URL" && -x "$CF" ]]; then
  : >"$LOG_DIR/tunnel.log"
  # http2 is more stable than quic for quick tunnels on some networks
  nohup "$CF" tunnel --protocol http2 --url http://127.0.0.1:8000 --no-autoupdate >"$LOG_DIR/tunnel.log" 2>&1 &
  echo $! >"$PID_DIR/tunnel.pid"
  for _ in $(seq 1 60); do
    CAND=$(grep -aoE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG_DIR/tunnel.log" 2>/dev/null \
      | grep -v 'api.trycloudflare.com' | tail -1 || true)
    if [[ -n "$CAND" ]] && curl -sf -m 15 "$CAND/api/v1/health" >/dev/null 2>&1; then
      URL="$CAND"
      break
    fi
    sleep 1
  done
fi

if [[ -z "$URL" ]]; then
  URL="http://$(demo_detect_lan_ip):8000"
  echo "[wamu] no public tunnel — Wi‑Fi only: $URL"
fi

# Pin URL files before watchdog so it does not race and rotate the tunnel.
demo_write_access "$URL"
echo "$URL" >"$LOG_DIR/tunnel_url.txt"
demo_write_share "$URL"

if [[ "$URL" == https://* ]]; then
  if [[ -f "$PID_DIR/watchdog.pid" ]]; then
    kill "$(cat "$PID_DIR/watchdog.pid")" 2>/dev/null || true
  fi
  nohup "$ROOT/infrastructure/phone_demo_watchdog.sh" >"$LOG_DIR/watchdog.log" 2>&1 &
  echo $! >"$PID_DIR/watchdog.pid"
fi

echo
echo "============================================"
echo "  Wamu is ON"
echo "  Share link:  $URL"
echo "  APK:         $URL/media-files/wamu-phone.apk"
echo "  Connect:     $URL/connect"
echo "  OTP:         123456"
echo "  Stop:        ./stop_wamu.sh"
echo "  Details:     $DIST/SHARE.txt"
echo "============================================"
echo
