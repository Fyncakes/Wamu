#!/usr/bin/env bash
# Make the phone demo ready: ensure API + public tunnel, pin DEMO_URL, run smoke.
# Prefer a named Cloudflare tunnel when configured; otherwise keep/restart quick tunnel.
#
# Usage (from repo root):
#   ./infrastructure/phone_demo_ready.sh
#   ./infrastructure/phone_demo_ready.sh --rebuild   # also rebuild Flutter web
#   ./infrastructure/phone_demo_ready.sh --restart-tunnel
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
LOG_DIR="$DIST/demo-logs"
PID_DIR="$DIST/demo-pids"
CF="$ROOT/.tools/cloudflared"
URL_FILE="$DIST/DEMO_URL.txt"
# shellcheck source=demo_access.sh
source "$ROOT/infrastructure/demo_access.sh"
export DEMO_ROOT="$ROOT"

REBUILD=0
RESTART_TUNNEL=0
for arg in "$@"; do
  case "$arg" in
    --rebuild) REBUILD=1 ;;
    --restart-tunnel) RESTART_TUNNEL=1 ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
  esac
done

mkdir -p "$DIST" "$LOG_DIR" "$PID_DIR"

echo "[ready] checking local API…"
if ! curl -sf -m 3 http://127.0.0.1:8000/api/v1/health >/dev/null 2>&1; then
  echo "[ready] starting API…"
  (
    cd "$ROOT/wamu-backend"
    nohup .venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload \
      >"$LOG_DIR/api.log" 2>&1 &
    echo $! >"$PID_DIR/api.pid"
  )
  for _ in $(seq 1 40); do
    curl -sf -m 2 http://127.0.0.1:8000/api/v1/health >/dev/null 2>&1 && break
    sleep 0.5
  done
fi
curl -sf -m 5 http://127.0.0.1:8000/api/v1/health >/dev/null
echo "[ready] API OK"

if [[ "$REBUILD" -eq 1 ]]; then
  echo "[ready] rebuilding Flutter web…"
  "$ROOT/infrastructure/phone_demo_rebuild_web.sh"
fi

# Prefer named tunnel config if present
NAMED_CFG=""
[[ -f "$DIST/NAMED_TUNNEL_CONFIG.txt" ]] && NAMED_CFG=$(cat "$DIST/NAMED_TUNNEL_CONFIG.txt")
[[ -z "$NAMED_CFG" && -f "$DIST/cloudflared-named.yml" ]] && NAMED_CFG="$DIST/cloudflared-named.yml"

pin_url() {
  local url="$1"
  demo_write_access "$url"
  echo "$url" >"$LOG_DIR/tunnel_url.txt"
}

health_url() {
  local url="$1"
  local code
  code=$(curl -sS -m 15 -o /dev/null -w '%{http_code}' "$url/api/v1/health" 2>/dev/null || echo 000)
  [[ "$code" == "200" ]]
}

CURRENT=""
[[ -f "$URL_FILE" ]] && CURRENT=$(cat "$URL_FILE" | tr -d '\r\n')

if [[ -n "$NAMED_CFG" && -f "$NAMED_CFG" ]]; then
  echo "[ready] named tunnel config: $NAMED_CFG"
  if [[ ! -f "$PID_DIR/tunnel.pid" ]] || ! kill -0 "$(cat "$PID_DIR/tunnel.pid" 2>/dev/null)" 2>/dev/null; then
    nohup "$CF" tunnel --config "$NAMED_CFG" run >"$LOG_DIR/tunnel.log" 2>&1 &
    echo $! >"$PID_DIR/tunnel.pid"
    sleep 2
  fi
  if [[ -f "$DIST/NAMED_TUNNEL_URL.txt" ]]; then
    CURRENT=$(cat "$DIST/NAMED_TUNNEL_URL.txt" | tr -d '\r\n')
  fi
elif [[ "$RESTART_TUNNEL" -eq 1 ]] || [[ -z "$CURRENT" ]] || ! health_url "$CURRENT"; then
  echo "[ready] public URL unhealthy or missing — restarting quick tunnel…"
  "$ROOT/infrastructure/restart_tunnel.sh" >/dev/null || true
  # restart_tunnel writes DEMO_URL when healthy
  CURRENT=$(cat "$URL_FILE" 2>/dev/null | tr -d '\r\n' || true)
  # Also scrape log if file stale
  if [[ -z "$CURRENT" ]] || ! health_url "$CURRENT"; then
    CURRENT=$(grep -aoE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG_DIR/tunnel.log" 2>/dev/null \
      | grep -v 'api.trycloudflare.com' | tail -1 || true)
  fi
fi

if [[ -z "$CURRENT" ]]; then
  echo "[ready] ERROR: no public URL. Run ./infrastructure/phone_demo_up.sh first." >&2
  exit 1
fi

if ! health_url "$CURRENT"; then
  echo "[ready] ERROR: $CURRENT health failed. Try --restart-tunnel" >&2
  exit 1
fi

pin_url "$CURRENT"
echo "[ready] DEMO_URL=$CURRENT"

# Watchdog if not running
if [[ ! -f "$PID_DIR/watchdog.pid" ]] || ! kill -0 "$(cat "$PID_DIR/watchdog.pid" 2>/dev/null)" 2>/dev/null; then
  nohup "$ROOT/infrastructure/phone_demo_watchdog.sh" >"$LOG_DIR/watchdog.log" 2>&1 &
  echo $! >"$PID_DIR/watchdog.pid"
  echo "[ready] watchdog started"
fi

echo "[ready] running smoke…"
"$ROOT/infrastructure/phone_demo_smoke.sh" "$CURRENT"
echo
echo "[ready] Phone Chrome → $CURRENT"
echo "[ready] OTP 123456  ·  ACCESS.md → $DIST/ACCESS.md"
if [[ ! -f "$DIST/cloudflared-named.yml" ]]; then
  echo "[ready] Tip: for a fixed hostname (no rotating URL), run:"
  echo "         ./infrastructure/setup_named_tunnel.sh --hostname your.domain"
fi
