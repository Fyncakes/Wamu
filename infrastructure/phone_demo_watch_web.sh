#!/usr/bin/env bash
# Watch Flutter/Dart sources and rebuild dist/web so the phone only needs Refresh.
# Usage: ./infrastructure/phone_demo_watch_web.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$ROOT/dist/demo-logs/web-watch.log"
mkdir -p "$ROOT/dist/demo-logs"

echo "[watch] rebuilding whenever wamu-mobile/lib changes…"
echo "[watch] phone: open DEMO URL in Chrome → pull to refresh after each rebuild"
echo "[watch] log: $LOG"

rebuild() {
  echo "[watch] $(date -Is) change detected — rebuilding web…" | tee -a "$LOG"
  if "$ROOT/infrastructure/phone_demo_rebuild_web.sh" >>"$LOG" 2>&1; then
    echo "[watch] $(date -Is) ready — refresh the phone" | tee -a "$LOG"
  else
    echo "[watch] $(date -Is) rebuild FAILED — see $LOG" | tee -a "$LOG"
  fi
}

# Initial build
rebuild

if command -v inotifywait >/dev/null 2>&1; then
  while inotifywait -r -e modify,create,delete,move \
    --exclude '(\.dart_tool|build/)' \
    "$ROOT/wamu-mobile/lib" "$ROOT/wamu-mobile/web" 2>/dev/null; do
    # Debounce burst edits
    sleep 1
    rebuild
  done
else
  echo "[watch] inotifywait missing — polling every 8s"
  LAST=""
  while true; do
    SIG=$(find "$ROOT/wamu-mobile/lib" -type f -name '*.dart' -printf '%T@ %p\n' 2>/dev/null | sort | md5sum | awk '{print $1}')
    if [[ "$SIG" != "$LAST" ]]; then
      LAST="$SIG"
      rebuild
    fi
    sleep 8
  done
fi
