#!/usr/bin/env bash
# Start coturn for phone demos (Docker preferred; host turnserver fallback).
# Also writes TURN_* into wamu-backend/.env so the demo API advertises ICE.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=demo_access.sh
source "$ROOT/infrastructure/demo_access.sh"

LAN=$(demo_detect_lan_ip)
USER_NAME="${TURN_USERNAME:-wamu}"
CRED="${TURN_CREDENTIAL:-staging-turn-change-me}"
LOG="$ROOT/dist/demo-logs"
PID_DIR="$ROOT/dist/demo-pids"
mkdir -p "$LOG" "$PID_DIR"

if [[ -n "${TURN_EXTERNAL_IP:-}" ]]; then
  LAN="$TURN_EXTERNAL_IP"
elif [[ "$LAN" == 127.* || "$LAN" == 1.0.0.* ]]; then
  # Prefer last demo LAN (written by phone_demo_*) then staging env
  if [[ -f "$ROOT/dist/LAN_IP.txt" ]]; then
    prev=$(tr -d '[:space:]' <"$ROOT/dist/LAN_IP.txt")
    if [[ -n "$prev" && "$prev" != 127.* && "$prev" != 1.0.0.* ]]; then
      LAN="$prev"
      echo "[turn] using dist/LAN_IP.txt → $LAN"
    fi
  fi
  if [[ "$LAN" == 127.* || "$LAN" == 1.0.0.* ]] && [[ -f "$ROOT/infrastructure/.env.staging" ]]; then
    prev=$(grep -E '^TURN_EXTERNAL_IP=' "$ROOT/infrastructure/.env.staging" | head -1 | cut -d= -f2- || true)
    if [[ -n "$prev" && "$prev" != 127.* && "$prev" != 1.0.0.* ]]; then
      LAN="$prev"
      echo "[turn] using previous TURN_EXTERNAL_IP=$LAN (current NIC not detected)"
    fi
  fi
fi

if [[ "$LAN" == 127.* || "$LAN" == 1.0.0.* ]]; then
  echo "[turn] WARN: LAN IP looks unreachable ($LAN)."
  echo "       Connect Wi‑Fi / Ethernet, then re-run:"
  echo "         ./infrastructure/start_turn_local.sh"
  echo "       Or: TURN_EXTERNAL_IP=x.x.x.x ./infrastructure/start_turn_local.sh"
  echo "       Skipping .env overwrite with loopback."
  exit 2
fi

TURN_EXTERNAL_IP="$LAN"
TURN_URLS="turn:${TURN_EXTERNAL_IP}:3478?transport=udp,turn:${TURN_EXTERNAL_IP}:3478?transport=tcp"

upsert_env() {
  local file="$1" key="$2" val="$3"
  touch "$file"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >>"$file"
  fi
}

for f in "$ROOT/wamu-backend/.env" "$ROOT/infrastructure/.env.staging"; do
  [[ -f "$f" ]] || continue
  upsert_env "$f" TURN_EXTERNAL_IP "$TURN_EXTERNAL_IP"
  upsert_env "$f" TURN_URLS "$TURN_URLS"
  upsert_env "$f" TURN_USERNAME "$USER_NAME"
  upsert_env "$f" TURN_CREDENTIAL "$CRED"
done

echo "[turn] ICE host: $TURN_EXTERNAL_IP"

started=0
if docker info >/dev/null 2>&1; then
  echo "[turn] starting coturn via docker compose…"
  docker compose -f "$ROOT/infrastructure/docker-compose.staging.yml" \
    --env-file "$ROOT/infrastructure/.env.staging" \
    --profile turn up -d coturn
  started=1
elif command -v turnserver >/dev/null 2>&1; then
  echo "[turn] docker unavailable — starting host turnserver…"
  if [[ -f "$PID_DIR/coturn.pid" ]] && kill -0 "$(cat "$PID_DIR/coturn.pid")" 2>/dev/null; then
    echo "[turn] already running pid=$(cat "$PID_DIR/coturn.pid")"
  else
    nohup turnserver -n \
      --log-file=stdout \
      --listening-port=3478 \
      --listening-ip=0.0.0.0 \
      --external-ip="$TURN_EXTERNAL_IP" \
      --min-port=49160 \
      --max-port=49200 \
      --fingerprint \
      --lt-cred-mech \
      --user="${USER_NAME}:${CRED}" \
      --realm=wamu.local \
      --no-cli --no-tls --no-dtls \
      >"$LOG/coturn.log" 2>&1 &
    echo $! >"$PID_DIR/coturn.pid"
  fi
  started=1
else
  echo "[turn] Neither Docker nor turnserver binary available."
  echo "       Install Docker Desktop / docker.io, then re-run this script."
  echo "       TURN_* was still written to .env for when coturn is up."
fi

echo "[turn] Restart API so it reloads TURN_* (phone_demo_restart_light / up)."
if [[ "$started" -eq 1 ]]; then
  echo "[turn] Check: curl -s http://127.0.0.1:8000/api/v1/health/rails | jq .ready_for_carrier_calls"
fi
