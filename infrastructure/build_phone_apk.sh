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
# Separate files stay small enough to share. A 64-bit-only APK shows
# "app isn't compatible with your phone" on 32-bit handsets.
flutter build apk --release --split-per-abi \
  --target-platform android-arm,android-arm64 \
  "${DEFINES[@]}"

ARM64="build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
ARM32="build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk"
if [[ ! -f "$ARM64" || ! -f "$ARM32" ]]; then
  echo "[apk] missing split APKs" >&2
  exit 1
fi

mkdir -p "$DIST/usb"
cp -f "$ARM64" "$DIST/wamu-arm64.apk"
cp -f "$ARM32" "$DIST/wamu-arm32.apk"
cp -f "$ARM64" "$DIST/wamu-phone.apk"
cp -f "$ARM64" "$DIST/usb/wamu-phone.apk"
cp -f "$ARM32" "$DIST/usb/wamu-arm32.apk"
rm -f "$ROOT/wamu-backend/media_uploads/wamu-phone.apk"
ln "$DIST/wamu-arm64.apk" "$ROOT/wamu-backend/media_uploads/wamu-phone.apk" 2>/dev/null \
  || cp -f "$DIST/wamu-arm64.apk" "$ROOT/wamu-backend/media_uploads/wamu-phone.apk"

echo "[apk] $DIST/wamu-arm64.apk ($(du -h "$DIST/wamu-arm64.apk" | awk '{print $1}'), 64-bit)"
echo "[apk] $DIST/wamu-arm32.apk ($(du -h "$DIST/wamu-arm32.apk" | awk '{print $1}'), 32-bit)"
