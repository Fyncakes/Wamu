#!/usr/bin/env bash
# Stop durable phone demo processes (API left running unless DEMO_KILL_API=1).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PID_DIR="$ROOT/dist/demo-pids"

for name in watchdog tunnel apk-http; do
  if [[ -f "$PID_DIR/$name.pid" ]]; then
    kill "$(cat "$PID_DIR/$name.pid")" 2>/dev/null || true
    rm -f "$PID_DIR/$name.pid"
    echo "[demo] stopped $name"
  fi
done

if [[ "${DEMO_KILL_API:-0}" == "1" ]] && [[ -f "$PID_DIR/api.pid" ]]; then
  kill "$(cat "$PID_DIR/api.pid")" 2>/dev/null || true
  rm -f "$PID_DIR/api.pid"
  echo "[demo] stopped api"
fi

echo "[demo] down"
