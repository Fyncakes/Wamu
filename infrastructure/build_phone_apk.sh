#!/usr/bin/env bash
# Build a release APK for both 32-bit and 64-bit Android phones.
# Optional dart-defines: API_BASE_URL=... or API_HOST=...
# Usage: ./infrastructure/build_phone_apk.sh
#        API_BASE_URL=https://x.lhr.life/api/v1 ./infrastructure/build_phone_apk.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
JAVA_HOME_DEFAULT="$ROOT/.tools/jdk-17.0.20.1+1"

export JAVA_HOME="${JAVA_HOME:-$JAVA_HOME_DEFAULT}"
export PATH="$JAVA_HOME/bin:${HOME}/flutter/bin:${PATH}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"

mkdir -p "$DIST" "$ROOT/wamu-backend/media_uploads"

DEFINES=()
if [[ -n "${API_BASE_URL:-}" ]]; then
  DEFINES+=(--dart-define="API_BASE_URL=$API_BASE_URL")
fi
if [[ -n "${API_HOST:-}" ]]; then
  DEFINES+=(--dart-define="API_HOST=$API_HOST")
fi

cd "$ROOT/wamu-mobile"
# One file with armeabi-v7a and arm64-v8a so either phone can install it.
flutter build apk --release "${DEFINES[@]}"

APK="build/app/outputs/flutter-apk/app-release.apk"
if [[ ! -f "$APK" ]]; then
  echo "[apk] missing $APK" >&2
  exit 1
fi

cp -f "$APK" "$DIST/wamu-phone.apk"
mkdir -p "$DIST/usb"
cp -f "$APK" "$DIST/usb/wamu-phone.apk"
rm -f "$ROOT/wamu-backend/media_uploads/wamu-phone.apk"
ln "$DIST/wamu-phone.apk" "$ROOT/wamu-backend/media_uploads/wamu-phone.apk" 2>/dev/null \
  || cp -f "$DIST/wamu-phone.apk" "$ROOT/wamu-backend/media_uploads/wamu-phone.apk"

SIZE=$(du -h "$DIST/wamu-phone.apk" | awk '{print $1}')
echo "[apk] $DIST/wamu-phone.apk ($SIZE, 32-bit and 64-bit)"
