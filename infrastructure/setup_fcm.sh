#!/usr/bin/env bash
# Firebase / FCM setup for Wamu Android APK push.
# Web Chrome demos work without this. Rider OS notifications need it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOBILE="$ROOT/wamu-mobile"
PKG="ug.wamu.wamu_mobile"
GS="$MOBILE/android/app/google-services.json"
OPTS="$MOBILE/lib/firebase_options.dart"

export PATH="${HOME}/flutter/bin:${HOME}/.pub-cache/bin:${PATH}"

echo "[fcm] Android package: $PKG"
echo "[fcm] Docs: $ROOT/infrastructure/setup_fcm.md"
echo

if [[ ! -f "$GS" ]]; then
  echo "[fcm] Missing google-services.json"
  echo "      1. https://console.firebase.google.com → project Wamu (wamu-f7877)"
  echo "      2. Add Android app with package: $PKG"
  echo "      3. Download google-services.json → $GS"
  exit 1
fi

PROJECT_ID=$(python3 - <<PY
import json
p = json.load(open("$GS"))
print(p["project_info"]["project_id"])
PY
)
echo "[fcm] Found $GS  (project=$PROJECT_ID)"

# Write lib/firebase_options.dart from google-services.json (no Firebase CLI).
python3 - <<'PY'
import json
from pathlib import Path
root = Path("/home/the-kola-s/Documents/WAMU/wamu-mobile")
gs = json.loads((root / "android/app/google-services.json").read_text())
info = gs["project_info"]
client = gs["client"][0]
api_key = client["api_key"][0]["current_key"]
app_id = client["client_info"]["mobilesdk_app_id"]
pid = info["project_id"]
sender = info["project_number"]
bucket = info.get("storage_bucket", f"{pid}.appspot.com")
path = root / "lib/firebase_options.dart"
text = path.read_text()
# If still placeholder, rewrite android block via the generator below
print(f"[fcm] project={pid} sender={sender}")
out = f'''// Generated from android/app/google-services.json (project {pid}).
// ignore_for_file: lines_longer_than_80_chars, avoid_classes_with_only_static_members

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {{
  static const String _placeholderProjectId = 'wamu-unconfigured';

  static FirebaseOptions get currentPlatform {{
    if (kIsWeb) {{
      return web;
    }}
    switch (defaultTargetPlatform) {{
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      default:
        return android;
    }}
  }}

  static bool get isConfigured =>
      currentPlatform.projectId != _placeholderProjectId;

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: '{api_key}',
    appId: '{app_id}',
    messagingSenderId: '{sender}',
    projectId: '{pid}',
    authDomain: '{pid}.firebaseapp.com',
    storageBucket: '{bucket}',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: '{api_key}',
    appId: '{app_id}',
    messagingSenderId: '{sender}',
    projectId: '{pid}',
    storageBucket: '{bucket}',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: '{api_key}',
    appId: '{app_id}',
    messagingSenderId: '{sender}',
    projectId: '{pid}',
    storageBucket: '{bucket}',
    iosBundleId: 'ug.wamu.wamuMobile',
  );

  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: '{api_key}',
    appId: '{app_id}',
    messagingSenderId: '{sender}',
    projectId: '{pid}',
    storageBucket: '{bucket}',
    iosBundleId: 'ug.wamu.wamuMobile',
  );
}}
'''
path.write_text(out)
print(f"[fcm] wrote {path}")
PY

if grep -q "projectId: 'wamu-unconfigured'" "$OPTS" 2>/dev/null; then
  echo "[fcm] WARN: firebase_options.dart still has placeholder projectId" >&2
  exit 1
fi
echo "[fcm] firebase_options.dart OK (projectId=$PROJECT_ID)"

echo
echo "[fcm] Optional: paste FCM Cloud Messaging server key, or press Enter to skip."
echo "       Firebase → Project settings (gear) → Cloud Messaging."
echo "       New projects often have no legacy key — skip is OK; in-app inbox still works."
read -r -s KEY || true
echo
if [[ -n "${KEY:-}" ]]; then
  for f in "$ROOT/wamu-backend/.env" "$ROOT/infrastructure/.env.staging"; do
    [[ -f "$f" ]] || continue
    if grep -q '^FCM_SERVER_KEY=' "$f"; then
      sed -i "s|^FCM_SERVER_KEY=.*|FCM_SERVER_KEY=${KEY}|" "$f"
    else
      echo "FCM_SERVER_KEY=${KEY}" >>"$f"
    fi
  done
  echo "[fcm] wrote FCM_SERVER_KEY to .env files"
else
  echo "[fcm] skipped backend FCM key (mock push / logs only)"
fi

echo "[fcm] rebuilding APK (this takes a few minutes)…"
"$ROOT/infrastructure/build_phone_apk.sh"

echo
echo "[fcm] Done. Restart the demo so the API reloads env:"
echo "  ./infrastructure/phone_demo_restart_light.sh"
echo "Install dist/wamu-phone.apk, login as rider, grant notifications."
