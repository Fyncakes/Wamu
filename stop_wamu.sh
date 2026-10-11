#!/usr/bin/env bash
# Stop everything started by ./start_wamu.sh (API + tunnel + watchdog + APK http).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PID_DIR="$ROOT/dist/demo-pids"
CF="$ROOT/.tools/cloudflared"

for name in watchdog tunnel apk-http api; do
  if [[ -f "$PID_DIR/$name.pid" ]]; then
    kill "$(cat "$PID_DIR/$name.pid")" 2>/dev/null || true
    sleep 0.2
    kill -9 "$(cat "$PID_DIR/$name.pid")" 2>/dev/null || true
    rm -f "$PID_DIR/$name.pid"
    echo "[wamu] stopped $name"
  fi
done

# Catch orphaned quick tunnels
pkill -f "$CF tunnel --url" 2>/dev/null || true
pkill -f "$CF tunnel --config" 2>/dev/null || true

# Free ports if still held
if command -v fuser >/dev/null 2>&1; then
  fuser -k 8000/tcp 2>/dev/null || true
  fuser -k 8088/tcp 2>/dev/null || true
fi

echo "[wamu] stopped — start again with ./start_wamu.sh"
