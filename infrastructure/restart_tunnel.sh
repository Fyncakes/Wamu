#!/usr/bin/env bash
set -u
ROOT=/home/the-kola-s/Documents/WAMU
LOG=$ROOT/dist/demo-logs
PIDDIR=$ROOT/dist/demo-pids
CF=$ROOT/.tools/cloudflared
OUT=$LOG/restart_tunnel.log
exec >"$OUT" 2>&1

echo "=== restart $(date -Is) ==="

kill_pidfile() {
  local f=$PIDDIR/$1.pid
  [[ -f $f ]] || return 0
  local p; p=$(cat "$f" || true)
  [[ -n "${p:-}" ]] || return 0
  kill "$p" 2>/dev/null || true
  sleep 0.3
  kill -9 "$p" 2>/dev/null || true
  rm -f "$f"
  echo "killed_pidfile $1 $p"
}

kill_pidfile watchdog
kill_pidfile tunnel

# Kill only processes whose argv0 is the cloudflared binary
for p in $(pgrep -x cloudflared 2>/dev/null || true); do
  echo "kill_cloudflared $p"
  kill -9 "$p" 2>/dev/null || true
done
sleep 2

if ! curl -sf -m 3 http://127.0.0.1:8000/api/v1/health >/dev/null; then
  echo start_api
  (
    cd "$ROOT/wamu-backend"
    nohup .venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload >"$LOG/api.log" 2>&1 &
    echo $! >"$PIDDIR/api.pid"
  )
  sleep 4
fi
curl -sf -m 3 http://127.0.0.1:8000/api/v1/health || { echo api_fail; exit 1; }
echo
echo api_ok

: >"$LOG/tunnel.log"
nohup "$CF" tunnel --url http://127.0.0.1:8000 --no-autoupdate >"$LOG/tunnel.log" 2>&1 &
TPID=$!
echo $TPID >"$PIDDIR/tunnel.pid"
echo tunnel_pid=$TPID

URL=""
for i in $(seq 1 60); do
  URL=$(grep -aoE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG/tunnel.log" 2>/dev/null \
    | grep -v '://api.trycloudflare.com' | head -1 || true)
  if [[ -n "$URL" ]]; then
    code=$(curl -s -m 15 -o /tmp/cf_h.json -w "%{http_code}" "$URL/api/v1/health" || echo 000)
    echo "i=$i url=$URL code=$code"
    if [[ "$code" == "200" ]]; then
      echo "$URL" >"$ROOT/dist/DEMO_URL.txt"
      echo "$URL/api/v1" >"$ROOT/dist/API_URL.txt"
      echo "$URL" >"$LOG/tunnel_url.txt"
      printf '# Wamu phone demo\n\nOpen Chrome: **%s**\nOTP: **123456**\n' "$URL" >"$ROOT/dist/PHONE_LOGIN.md"
      nohup "$ROOT/infrastructure/phone_demo_watchdog.sh" >"$LOG/watchdog.log" 2>&1 &
      echo $! >"$PIDDIR/watchdog.pid"
      curl -sf -m 12 -o /dev/null -w "root:%{http_code}\n" "$URL/" || true
      echo DEMO_URL=$URL
      echo DONE
      exit 0
    fi
  else
    echo waiting_$i
  fi
  sleep 2
done

echo FAILED
tail -40 "$LOG/tunnel.log" | tr -cd '\11\12\15\40-\176\n'
exit 1
