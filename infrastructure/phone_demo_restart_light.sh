#!/usr/bin/env bash
# Restart API + public tunnel + watchdog without rebuilding Flutter web.
# Always kills duplicate uvicorn/cloudflared first — duplicate APIs cause
# tunnel Error 1033 / health:000 even when a URL is printed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$ROOT/dist/demo-logs"
PID="$ROOT/dist/demo-pids"
CF="$ROOT/.tools/cloudflared"
# shellcheck source=demo_access.sh
source "$ROOT/infrastructure/demo_access.sh"
export DEMO_ROOT="$ROOT"

mkdir -p "$LOG" "$PID" "$ROOT/dist/web"

kill_demo_stack() {
  echo "[demo] stopping old API / tunnel / watchdog…"
  for f in tunnel.pid watchdog.pid api.pid apk-http.pid; do
    if [[ -f "$PID/$f" ]]; then
      kill "$(cat "$PID/$f")" 2>/dev/null || true
      rm -f "$PID/$f"
    fi
  done
  # Broad cleanup — Cursor/agent + manual restarts leave orphans on :8000
  pkill -9 -f 'cloudflared tunnel' 2>/dev/null || true
  pkill -9 -f 'phone_demo_watchdog' 2>/dev/null || true
  pkill -9 -f 'uvicorn app.main:app' 2>/dev/null || true
  pkill -9 -f 'python3 -m http.server 8088' 2>/dev/null || true
  if command -v fuser >/dev/null 2>&1; then
    fuser -k 8000/tcp 2>/dev/null || true
    fuser -k 8088/tcp 2>/dev/null || true
  fi
  sleep 2
}

kill_demo_stack

echo "[demo] ensuring web assets…"
if [[ ! -f "$ROOT/dist/web/index.html" ]]; then
  if [[ -f "$ROOT/wamu-mobile/build/web/index.html" ]]; then
    rm -rf "$ROOT/dist/web"
    cp -a "$ROOT/wamu-mobile/build/web" "$ROOT/dist/web"
    rm -f "$ROOT/dist/web/flutter_service_worker.js" || true
  else
    echo "Missing dist/web and mobile build/web" >&2
    exit 1
  fi
fi

echo "[demo] starting API (single instance)…"
(
  cd "$ROOT/wamu-backend"
  nohup .venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload \
    >"$LOG/api.log" 2>&1 &
  echo $! >"$PID/api.pid"
)
ok=0
for _ in $(seq 1 60); do
  if curl -sf -m 2 http://127.0.0.1:8000/api/v1/health >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 0.4
done
if [[ "$ok" -ne 1 ]]; then
  echo "API failed; last log:" >&2
  tail -40 "$LOG/api.log" >&2 || true
  exit 1
fi
echo "[demo] API healthy"
curl -sf http://127.0.0.1:8000/api/v1/health
echo

(
  cd "$ROOT/dist"
  nohup python3 -m http.server 8088 --bind 0.0.0.0 >"$LOG/apk-http.log" 2>&1 &
  echo $! >"$PID/apk-http.pid"
)
echo "[demo] apk-http on :8088"

URL=""
if [[ -f "$ROOT/dist/NAMED_TUNNEL_CONFIG.txt" && -f "$ROOT/dist/NAMED_TUNNEL_URL.txt" ]]; then
  NAMED_CFG=$(cat "$ROOT/dist/NAMED_TUNNEL_CONFIG.txt")
  NAMED_URL=$(cat "$ROOT/dist/NAMED_TUNNEL_URL.txt")
  if [[ -f "$NAMED_CFG" && -x "$CF" ]]; then
    echo "[demo] starting named Cloudflare tunnel → $NAMED_URL"
    : >"$LOG/tunnel.log"
    nohup "$CF" tunnel --config "$NAMED_CFG" run --no-autoupdate >"$LOG/tunnel.log" 2>&1 &
    echo $! >"$PID/tunnel.pid"
    for _ in $(seq 1 40); do
      if curl -sf -m 12 "$NAMED_URL/api/v1/health" >/dev/null 2>&1; then
        URL="$NAMED_URL"
        break
      fi
      sleep 1
    done
  fi
fi

if [[ -z "$URL" ]]; then
  echo "[demo] starting cloudflared quick tunnel…"
  [[ -x "$CF" ]] || { echo "missing $CF" >&2; exit 1; }
  : >"$LOG/tunnel.log"
  nohup "$CF" tunnel --url http://127.0.0.1:8000 --no-autoupdate >"$LOG/tunnel.log" 2>&1 &
  echo $! >"$PID/tunnel.pid"

  for _ in $(seq 1 75); do
    CAND=$(grep -aoE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG/tunnel.log" 2>/dev/null | grep -v '://api.trycloudflare.com' | head -1 || true)
    if [[ -n "$CAND" ]]; then
      # Wait until tunnel can actually reach local API (not just URL printed)
      if curl -sf -m 12 "$CAND/api/v1/health" >/dev/null 2>&1; then
        URL="$CAND"
        break
      fi
    fi
    sleep 1
  done
fi

if [[ -z "$URL" ]]; then
  echo "[demo] WARN: public tunnel not healthy — using Wi‑Fi only" >&2
  tail -25 "$LOG/tunnel.log" >&2 || true
  URL="http://$(demo_detect_lan_ip):8000"
fi

echo "$URL" >"$LOG/tunnel_url.txt"

if [[ "$URL" == https://* ]]; then
  nohup "$ROOT/infrastructure/phone_demo_watchdog.sh" >"$LOG/watchdog.log" 2>&1 &
  echo $! >"$PID/watchdog.pid"
fi

demo_write_access "$URL"

# Keep TURN_* aligned with current Wi‑Fi so coturn start is one command later
if [[ -f "$ROOT/dist/LAN_IP.txt" ]]; then
  _lan=$(tr -d '[:space:]' <"$ROOT/dist/LAN_IP.txt")
  if [[ -n "$_lan" && "$_lan" != 127.* && "$_lan" != 1.0.0.* ]]; then
    for _f in "$ROOT/wamu-backend/.env" "$ROOT/infrastructure/.env.staging"; do
      [[ -f "$_f" ]] || continue
      sed -i "s|^TURN_EXTERNAL_IP=.*|TURN_EXTERNAL_IP=${_lan}|" "$_f" 2>/dev/null || true
      sed -i "s|^TURN_URLS=.*|TURN_URLS=turn:${_lan}:3478?transport=udp,turn:${_lan}:3478?transport=tcp|" "$_f" 2>/dev/null || true
    done
  fi
fi

APP_CODE=$(curl -sS -m 20 -o /dev/null -w "%{http_code}" "$URL/" || true)
HEALTH_CODE=$(curl -sS -m 20 -o /dev/null -w "%{http_code}" "$URL/api/v1/health" || true)
APP_CODE=${APP_CODE:-000}
HEALTH_CODE=${HEALTH_CODE:-000}
echo "app:${APP_CODE}"
echo "health:${HEALTH_CODE}"
if [[ "$APP_CODE" != "200" || "$HEALTH_CODE" != "200" ]]; then
  echo
  echo "[demo] WARNING: public/Wi‑Fi URL did not return 200." >&2
  echo "       Prefer Wi‑Fi: http://$(demo_detect_lan_ip):8000" >&2
  echo "       Or re-run after: pkill -f 'uvicorn app.main:app'; pkill -f 'cloudflared tunnel'" >&2
fi
