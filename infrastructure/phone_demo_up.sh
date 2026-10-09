#!/usr/bin/env bash
# Durable phone demo: API + Flutter web (same origin) + public tunnel + watchdog.
# Phone: open the printed https://… URL in Chrome → refresh to see UI rebuilds.
# Usage (from repo root):
#   ./infrastructure/phone_demo_up.sh
# Rebuild UI after code changes (then refresh phone):
#   ./infrastructure/phone_demo_rebuild_web.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
LOG_DIR="$DIST/demo-logs"
PID_DIR="$DIST/demo-pids"
URL_FILE="$DIST/DEMO_URL.txt"
CF="$ROOT/.tools/cloudflared"
JAVA_HOME_DEFAULT="$ROOT/.tools/jdk-17.0.20.1+1"
# shellcheck source=demo_access.sh
source "$ROOT/infrastructure/demo_access.sh"
export DEMO_ROOT="$ROOT"

mkdir -p "$DIST" "$LOG_DIR" "$PID_DIR" "$ROOT/wamu-backend/media_uploads"

export JAVA_HOME="${JAVA_HOME:-$JAVA_HOME_DEFAULT}"
export PATH="$JAVA_HOME/bin:${HOME}/flutter/bin:$PATH"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"

echo "[demo] ensuring API is up…"
if ! curl -sf -m 2 http://127.0.0.1:8000/api/v1/health >/dev/null 2>&1; then
  # stop stale listeners carefully by port
  if command -v fuser >/dev/null 2>&1; then
    fuser -k 8000/tcp 2>/dev/null || true
  fi
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
curl -sf http://127.0.0.1:8000/api/v1/health
echo

echo "[demo] building Flutter web (same-origin API)…"
"$ROOT/infrastructure/phone_demo_rebuild_web.sh"

echo "[demo] APK download server on :8088…"
if ! ss -tln | grep -q ':8088'; then
  (
    cd "$DIST"
    nohup python3 -m http.server 8088 --bind 0.0.0.0 >"$LOG_DIR/apk-http.log" 2>&1 &
    echo $! >"$PID_DIR/apk-http.pid"
  )
fi

start_cloudflared() {
  [[ -x "$CF" ]] || return 1
  nohup "$CF" tunnel --url http://127.0.0.1:8000 --no-autoupdate >"$LOG_DIR/tunnel.log" 2>&1 &
  echo $! >"$PID_DIR/tunnel.pid"
  for i in $(seq 1 45); do
    URL=$(grep -aoE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG_DIR/tunnel.log" 2>/dev/null | grep -v '://api.trycloudflare.com' | head -1 || true)
    if [[ -n "${URL:-}" ]]; then
      echo "$URL" >"$URL_FILE"
      sleep 1
      if curl -sf -m 15 "$URL/api/v1/health" >/dev/null; then
        echo "$URL"
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

start_localhost_run() {
  ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
    -R 80:127.0.0.1:8000 nokey@localhost.run >"$LOG_DIR/tunnel.log" 2>&1 &
  echo $! >"$PID_DIR/tunnel.pid"
  for i in $(seq 1 45); do
    URL=$(grep -aoE 'https://[a-z0-9]+\.lhr\.life' "$LOG_DIR/tunnel.log" 2>/dev/null | head -1 || true)
    if [[ -n "${URL:-}" ]]; then
      echo "$URL" >"$URL_FILE"
      sleep 2
      if curl -sf -m 15 "$URL/api/v1/health" >/dev/null; then
        echo "$URL"
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

# Drop stale tunnel process if any
if [[ -f "$PID_DIR/tunnel.pid" ]]; then
  kill "$(cat "$PID_DIR/tunnel.pid")" 2>/dev/null || true
fi
# also clear known ssh tunnels to localhost.run (by exact binary args is hard; leave watchdog)

echo "[demo] starting public tunnel…"
URL=""
# Prefer named (fixed) tunnel if configured
if [[ -f "$DIST/NAMED_TUNNEL_CONFIG.txt" && -f "$DIST/NAMED_TUNNEL_URL.txt" ]]; then
  NAMED_CFG=$(cat "$DIST/NAMED_TUNNEL_CONFIG.txt")
  NAMED_URL=$(cat "$DIST/NAMED_TUNNEL_URL.txt")
  if [[ -f "$NAMED_CFG" && -x "$CF" ]]; then
    echo "[demo] starting named Cloudflare tunnel → $NAMED_URL"
    nohup "$CF" tunnel --config "$NAMED_CFG" run --no-autoupdate >"$LOG_DIR/tunnel.log" 2>&1 &
    echo $! >"$PID_DIR/tunnel.pid"
    for i in $(seq 1 30); do
      if curl -sf -m 12 "$NAMED_URL/api/v1/health" >/dev/null 2>&1; then
        URL="$NAMED_URL"
        break
      fi
      sleep 1
    done
  fi
fi
# Prefer Cloudflare quick tunnel; fall back to localhost.run
if [[ -z "$URL" ]]; then
  if URL=$(start_cloudflared); then
    echo "[demo] tunnel via cloudflared (quick — URL changes on restart)"
  elif URL=$(start_localhost_run); then
    echo "[demo] tunnel via localhost.run"
  else
    echo "[demo] FAILED to open public tunnel — see $LOG_DIR/tunnel.log" >&2
    echo "[demo] Wi‑Fi still works: http://$(demo_detect_lan_ip):8000" >&2
    URL=""
  fi
fi

if [[ -z "$URL" ]]; then
  # No public tunnel — still publish LAN access for same-Wi‑Fi testers
  URL="http://$(demo_detect_lan_ip):8000"
  echo "[demo] using Wi‑Fi-only URL: $URL"
fi

# Watchdog (restart tunnel if health fails) — skip for pure LAN
if [[ "$URL" == https://* ]]; then
  if [[ -f "$PID_DIR/watchdog.pid" ]]; then
    kill "$(cat "$PID_DIR/watchdog.pid")" 2>/dev/null || true
  fi
  nohup "$ROOT/infrastructure/phone_demo_watchdog.sh" >"$LOG_DIR/watchdog.log" 2>&1 &
  echo $! >"$PID_DIR/watchdog.pid"
fi

demo_write_access "$URL"
echo "  Rebuild UI: ./infrastructure/phone_demo_rebuild_web.sh"
echo "  Fixed URL:  ./infrastructure/setup_named_tunnel.sh"
echo "  TURN:       ./infrastructure/start_turn_local.sh"
echo "  Stop:       ./infrastructure/phone_demo_down.sh"
echo
