#!/usr/bin/env bash
# Rebuild Flutter web into dist/web (served by the API). Then refresh phone Chrome.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JAVA_HOME_DEFAULT="$ROOT/.tools/jdk-17.0.20.1+1"
export JAVA_HOME="${JAVA_HOME:-$JAVA_HOME_DEFAULT}"
export PATH="$JAVA_HOME/bin:${HOME}/flutter/bin:$PATH"

cd "$ROOT/wamu-mobile"
echo "[demo] flutter build web…"
# Local canvaskit (phone may block gstatic CDN) — avoids blank white screen.
# HtmlElementView renders remote/local video reliably on Flutter web.
flutter build web --release --no-web-resources-cdn \
  --dart-define=WEBRTC_USE_HTML_ELEMENT_VIEW=true
mkdir -p "$ROOT/dist"
rm -rf "$ROOT/dist/web"
cp -a build/web "$ROOT/dist/web"

# Soft refresh must always pick up new JS — disable Flutter's service worker cache.
rm -f "$ROOT/dist/web/flutter_service_worker.js"
if [[ -f "$ROOT/dist/web/flutter_bootstrap.js" ]]; then
  sed -i 's/serviceWorkerSettings:[[:space:]]*{[^}]*}/serviceWorkerSettings: undefined/g' \
    "$ROOT/dist/web/flutter_bootstrap.js" 2>/dev/null || true
fi
BUILD_ID="$(date +%s)"
if [[ -f "$ROOT/dist/web/index.html" ]]; then
  if ! grep -q 'wamu-build' "$ROOT/dist/web/index.html"; then
    sed -i "s|<title>Wamu</title>|<meta name=\"wamu-build\" content=\"${BUILD_ID}\">\\n  <meta http-equiv=\"Cache-Control\" content=\"no-cache, no-store, must-revalidate\">\\n  <title>Wamu</title>|" \
      "$ROOT/dist/web/index.html"
  else
    sed -i "s|content=\"[0-9]*\"|content=\"${BUILD_ID}\"|" "$ROOT/dist/web/index.html"
  fi
fi
echo "$BUILD_ID" >"$ROOT/dist/web/.wamu_build_id"

# Force uvicorn --reload to re-import main.py so / mounts Flutter web
touch "$ROOT/wamu-backend/app/main.py"
sleep 2
echo "[demo] web ready at dist/web — refresh the phone browser"
if [[ -f "$ROOT/dist/DEMO_URL.txt" ]]; then
  echo "[demo] open: $(cat "$ROOT/dist/DEMO_URL.txt")"
elif [[ -f "$ROOT/dist/demo-logs/tunnel_url.txt" ]]; then
  echo "[demo] open: $(cat "$ROOT/dist/demo-logs/tunnel_url.txt")"
fi
if curl -sf -m 3 http://127.0.0.1:8000/ | head -c 120 | grep -qi '<!doctype\|<html\|Loading Wamu'; then
  echo "[demo] local / is serving Flutter web OK"
else
  echo "[demo] WARN: / not serving HTML yet — restart API (./infrastructure/phone_demo_up.sh)" >&2
fi
