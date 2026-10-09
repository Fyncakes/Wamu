#!/usr/bin/env bash
# Force Cloudflare quick tunnel (no localhost.run). Avoid pkill patterns that match this script.
set -u
ROOT=/home/the-kola-s/Documents/WAMU
LOG=$ROOT/dist/demo-logs
PIDDIR=$ROOT/dist/demo-pids
CF=$ROOT/.tools/cloudflared
exec > >(tee "$LOG/force_cf.log") 2>&1

echo "=== force cf $(date -Is) ==="

stop_pidfile() {
  local name=$1
  local f=$PIDDIR/$name.pid
  if [[ -f $f ]]; then
    local p
    p=$(cat "$f" 2>/dev/null || true)
    if [[ -n "${p:-}" ]]; then
      kill "$p" 2>/dev/null || true
      sleep 0.5
      kill -9 "$p" 2>/dev/null || true
    fi
    rm -f "$f"
    echo "stopped $name ($p)"
  fi
}

stop_pidfile watchdog
stop_pidfile tunnel

# Kill only real cloudflared/ssh tunnel processes by reading /proc (not pkill -f)
while read -r p cmd; do
  case "$cmd" in
    *'/.tools/cloudflared tunnel --url'*|*'cloudflared tunnel --url http://127.0.0.1:8000'*)
      echo "kill cf $p"; kill -9 "$p" 2>/dev/null || true ;;
    *'nokey@localhost.run'*)
      echo "kill lhr $p"; kill -9 "$p" 2>/dev/null || true ;;
  esac
done < <(ps -eo pid=,args=)

sleep 2

if ! curl -sf -m 3 http://127.0.0.1:8000/api/v1/health >/dev/null; then
  echo starting_api
  (
    cd "$ROOT/wamu-backend"
    nohup .venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload >"$LOG/api.log" 2>&1 &
    echo $! >"$PIDDIR/api.pid"
  )
  for _ in $(seq 1 30); do
    curl -sf -m 2 http://127.0.0.1:8000/api/v1/health >/dev/null && break
    sleep 0.5
  done
fi
curl -sf -m 3 http://127.0.0.1:8000/api/v1/health || { echo api_fail; exit 1; }
echo
echo api_ok

: >"$LOG/tunnel.log"
nohup "$CF" tunnel --url http://127.0.0.1:8000 --no-autoupdate >"$LOG/tunnel.log" 2>&1 &
echo $! >"$PIDDIR/tunnel.pid"
echo tunnel_pid=$(cat "$PIDDIR/tunnel.pid")

URL=""
for i in $(seq 1 55); do
  URL=$(grep -aoE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG/tunnel.log" 2>/dev/null \
    | grep -v '://api.trycloudflare.com' | head -1 || true)
  if [[ -n "$URL" ]]; then
    echo "candidate=$URL i=$i"
    if curl -sf -m 15 "$URL/api/v1/health" >/dev/null 2>&1; then
      echo health_ok
      break
    fi
  else
    echo "waiting i=$i"
  fi
  sleep 1
done

if [[ -z "$URL" ]] || ! curl -sf -m 15 "$URL/api/v1/health" >/dev/null; then
  echo FAILED
  tail -50 "$LOG/tunnel.log" | tr -cd '\11\12\15\40-\176\n'
  exit 1
fi

echo "$URL" >"$ROOT/dist/DEMO_URL.txt"
echo "$URL/api/v1" >"$ROOT/dist/API_URL.txt"
echo "$URL" >"$LOG/tunnel_url.txt"
printf '# Wamu phone demo\n\nOpen Chrome: **%s**\nOTP: **123456**\n' "$URL" >"$ROOT/dist/PHONE_LOGIN.md"

nohup "$ROOT/infrastructure/phone_demo_watchdog.sh" >"$LOG/watchdog.log" 2>&1 &
echo $! >"$PIDDIR/watchdog.pid"

curl -sf -m 12 -o /dev/null -w "root:%{http_code}\n" "$URL/"
curl -sf -m 12 -o /dev/null -w "health:%{http_code}\n" "$URL/api/v1/health"
echo DEMO_URL=$URL
ps -p "$(cat $PIDDIR/tunnel.pid)" -o pid=,cmd= || true
echo DONE
