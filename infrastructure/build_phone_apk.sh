#!/usr/bin/env bash
# Build a small arm64 release APK into dist/wamu-phone.apk (~38MB).
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
# Universal APK is ~100MB+; phones are almost all arm64 → ship the thin build.
flutter build apk --release --split-per-abi "${DEFINES[@]}"

ARM64="build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
if [[ ! -f "$ARM64" ]]; then
  echo "[apk] missing $ARM64" >&2
  exit 1
fi

cp -f "$ARM64" "$DIST/wamu-phone.apk"
mkdir -p "$DIST/usb"
cp -f "$ARM64" "$DIST/usb/wamu-phone.apk"
rm -f "$ROOT/wamu-backend/media_uploads/wamu-phone.apk"
ln "$DIST/wamu-phone.apk" "$ROOT/wamu-backend/media_uploads/wamu-phone.apk" 2>/dev/null \
  || cp -f "$DIST/wamu-phone.apk" "$ROOT/wamu-backend/media_uploads/wamu-phone.apk"

SIZE=$(du -h "$DIST/wamu-phone.apk" | awk '{print $1}')
echo "[apk] $DIST/wamu-phone.apk ($SIZE arm64)"
