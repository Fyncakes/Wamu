#!/usr/bin/env bash
# Keep API + public tunnel alive for phone demos. Restarts tunnel when health fails.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
LOG_DIR="$DIST/demo-logs"
PID_DIR="$DIST/demo-pids"
URL_FILE="$DIST/DEMO_URL.txt"
CF="$ROOT/.tools/cloudflared"

mkdir -p "$LOG_DIR" "$PID_DIR"

ensure_api() {
  if curl -sf -m 2 http://127.0.0.1:8000/api/v1/health >/dev/null 2>&1; then
    return 0
  fi
  echo "[watchdog $(date -Is)] API down — restarting"
  (
    cd "$ROOT/wamu-backend"
    nohup .venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload \
      >"$LOG_DIR/api.log" 2>&1 &
    echo $! >"$PID_DIR/api.pid"
  )
  sleep 2
}

tunnel_ok() {
  local url
  url="$(cat "$URL_FILE" 2>/dev/null || true)"
  [[ -n "$url" ]] || return 1
  curl -sf -m 12 "$url/api/v1/health" >/dev/null 2>&1
}

start_tunnel() {
  if [[ -f "$PID_DIR/tunnel.pid" ]]; then
    kill "$(cat "$PID_DIR/tunnel.pid")" 2>/dev/null || true
    sleep 1
  fi
  : >"$LOG_DIR/tunnel.log"

  # Cloudflare quick tunnel only
  if [[ -x "$CF" ]]; then
    nohup "$CF" tunnel --url http://127.0.0.1:8000 --no-autoupdate >"$LOG_DIR/tunnel.log" 2>&1 &
    echo $! >"$PID_DIR/tunnel.pid"
    for i in $(seq 1 45); do
      URL=$(grep -aoE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG_DIR/tunnel.log" 2>/dev/null | grep -v '://api.trycloudflare.com' | head -1 || true)
      if [[ -n "${URL:-}" ]]; then
        echo "$URL" >"$URL_FILE"
        echo "${URL}/api/v1" >"$DIST/API_URL.txt"
        sleep 2
        curl -sf -m 12 "$URL/api/v1/health" >/dev/null 2>&1 && {
          echo "[watchdog $(date -Is)] cloudflared OK $URL"
          return 0
        }
      fi
      sleep 1
    done
    kill "$(cat "$PID_DIR/tunnel.pid")" 2>/dev/null || true
  fi

  echo "[watchdog $(date -Is)] tunnel start FAILED (cloudflared)"
  return 1
}

echo "[watchdog] started pid=$$"
while true; do
  ensure_api || true
  if ! tunnel_ok; then
    echo "[watchdog $(date -Is)] tunnel unhealthy — restarting"
    start_tunnel || true
  fi
  sleep 25
done
