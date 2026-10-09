#!/usr/bin/env bash
set -u
ROOT=/home/the-kola-s/Documents/WAMU
LOG=$ROOT/dist/demo-logs
PID=$ROOT/dist/demo-pids
CF=$ROOT/.tools/cloudflared
OUT=$LOG/switch_cf.log
exec > >(tee "$OUT") 2>&1

echo "=== switch to cloudflare $(date -Is) ==="

if [[ -f $PID/watchdog.pid ]]; then
  kill "$(cat $PID/watchdog.pid)" 2>/dev/null || true
  rm -f $PID/watchdog.pid
  echo stopped_watchdog
fi
if [[ -f $PID/tunnel.pid ]]; then
  kill "$(cat $PID/tunnel.pid)" 2>/dev/null || true
  rm -f $PID/tunnel.pid
  echo stopped_tunnel_pid
fi
pkill -f 'nokey@localhost.run' 2>/dev/null || true
pkill -f 'cloudflared tunnel --url' 2>/dev/null || true
sleep 2

if ! curl -sf -m 3 http://127.0.0.1:8000/api/v1/health >/dev/null; then
  echo starting_api
  cd "$ROOT/wamu-backend"
  nohup .venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload >"$LOG/api.log" 2>&1 &
  echo $! >"$PID/api.pid"
  sleep 4
fi
curl -sf -m 3 http://127.0.0.1:8000/api/v1/health || { echo api_fail; exit 1; }
echo
echo api_ok

: >"$LOG/tunnel.log"
nohup "$CF" tunnel --url http://127.0.0.1:8000 --no-autoupdate >"$LOG/tunnel.log" 2>&1 &
echo $! >"$PID/tunnel.pid"
echo tunnel_pid=$(cat $PID/tunnel.pid)

URL=""
for i in $(seq 1 55); do
  URL=$(grep -aoE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG/tunnel.log" 2>/dev/null | grep -v '://api.trycloudflare.com' | head -1 || true)
  if [[ -n "$URL" ]]; then
    echo "candidate=$URL i=$i"
    if curl -sf -m 15 "$URL/api/v1/health" >/dev/null 2>&1; then
      echo health_ok
      break
    fi
  else
    echo "waiting_url i=$i"
  fi
  sleep 1
done

if [[ -z "$URL" ]]; then
  echo NO_URL
  tail -50 "$LOG/tunnel.log"
  exit 1
fi

if ! curl -sf -m 15 "$URL/api/v1/health" >/dev/null; then
  echo HEALTH_FAIL
  tail -50 "$LOG/tunnel.log"
  exit 1
fi

echo "$URL" >"$ROOT/dist/DEMO_URL.txt"
echo "$URL/api/v1" >"$ROOT/dist/API_URL.txt"
echo "$URL" >"$LOG/tunnel_url.txt"
printf '# Wamu phone demo\n\nOpen Chrome: **%s**\nOTP: **123456**\n' "$URL" >"$ROOT/dist/PHONE_LOGIN.md"

nohup "$ROOT/infrastructure/phone_demo_watchdog.sh" >"$LOG/watchdog.log" 2>&1 &
echo $! >"$PID/watchdog.pid"
echo watchdog_pid=$(cat $PID/watchdog.pid)

curl -sf -m 15 -o /dev/null -w "root:%{http_code}\n" "$URL/"
curl -sf -m 15 -o /dev/null -w "health:%{http_code}\n" "$URL/api/v1/health"
curl -sf -m 15 -o /dev/null -w "videos:%{http_code}\n" "$URL/api/v1/discover/videos?limit=2"
echo DEMO_URL=$URL
ps -p "$(cat $PID/tunnel.pid)" -o pid=,cmd= || true
echo DONE
