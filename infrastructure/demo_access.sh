#!/usr/bin/env bash
# Shared helpers: detect LAN IP and print durable tester access banner.
# Sourced by phone_demo_up.sh / phone_demo_restart_light.sh

demo_detect_lan_ip() {
  local ip=""
  # Prefer route to public DNS (real NIC, not tunnel/VPN loopbacks)
  if command -v ip >/dev/null 2>&1; then
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
  fi
  if [[ -z "$ip" || "$ip" == 127.* || "$ip" == 1.0.0.* ]]; then
    ip=$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '
      $0 ~ /^127\./ { next }
      $0 ~ /^1\.0\.0\./ { next }
      $0 ~ /^169\.254\./ { next }
      { print; exit }
    ')
  fi
  if [[ -z "$ip" || "$ip" == 127.* ]]; then
    ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  fi
  echo "${ip:-127.0.0.1}"
}

# Args: PUBLIC_URL
demo_write_access() {
  local URL="${1:?public url required}"
  local ROOT="${DEMO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local DIST="$ROOT/dist"
  local LAN
  LAN=$(demo_detect_lan_ip)
  local BUILD_ID=""
  [[ -f "$DIST/web/.wamu_build_id" ]] && BUILD_ID=$(cat "$DIST/web/.wamu_build_id")

  mkdir -p "$DIST"
  echo "$URL" >"$DIST/DEMO_URL.txt"
  echo "${URL}/api/v1" >"$DIST/API_URL.txt"
  echo "$LAN" >"$DIST/LAN_IP.txt"

  cat >"$DIST/ACCESS.md" <<EOF
# Wamu — share access

Keep the **PC awake** while friends are testing. Quick tunnels change URL when restarted — run \`./start_wamu.sh\` again and share the new link.

## Public (any network / mobile data)

- **App (Chrome):** ${URL}
- **Connect (APK):** ${URL}/connect
- **APK download:** ${URL}/media-files/wamu-phone.apk
- **Health:** ${URL}/api/v1/health
- **OTP:** \`123456\`

If Chrome shows Error **1033**, the tunnel died — on the PC run \`./start_wamu.sh\` and share the new URL.

## Wi‑Fi (same network as PC)

- **App:** http://${LAN}:8000
- **APK:** http://${LAN}:8088/wamu-phone.apk
- **Connect:** http://${LAN}:8000/connect

## Native APK

1. Install \`wamu-phone.apk\` (USB from \`dist/wamu-phone.apk\`, or download link above).
2. Open app → set server via **${URL}/connect** (or You → Wamu server).

## One control on this PC

\`\`\`bash
./start_wamu.sh          # start
./stop_wamu.sh           # stop
./start_wamu.sh --apk    # start + rebuild APK
\`\`\`

## Fixed public URL (optional)

\`\`\`bash
./infrastructure/setup_named_tunnel.sh --hostname wamu.yourdomain.com
./start_wamu.sh
\`\`\`

## Build id

${BUILD_ID:-unknown}
EOF

  cat >"$DIST/TESTER_BRIEF.md" <<EOF
# Wamu tester brief

**App (public):** ${URL}
**App (Wi‑Fi):** http://${LAN}:8000
**OTP:** \`123456\`

Hard-refresh if the page looks old. Ignore old trycloudflare bookmarks (Error 1033).

**APK:** http://${LAN}:8088/wamu-phone.apk — then paste \`${URL}/connect\` in the app.
EOF

  cat >"$DIST/PHONE_LOGIN.md" <<EOF
# Wamu phone demo

## Public
Open Chrome: **${URL}**
OTP: **123456**

## Same Wi‑Fi as PC
Open: **http://${LAN}:8000**

## APK
http://${LAN}:8088/wamu-phone.apk → paste ${URL}/connect

Stop: \`./infrastructure/phone_demo_down.sh\`
EOF

  echo
  echo "============================================"
  echo "  PUBLIC APP:   $URL"
  echo "  WI-FI APP:    http://${LAN}:8000"
  echo "  APK (Wi-Fi):  http://${LAN}:8088/wamu-phone.apk"
  echo "  CONNECT:      $URL/connect"
  echo "  OTP:          123456"
  echo "  Access file:  $DIST/ACCESS.md"
  echo "============================================"
}

# Args: PUBLIC_URL — friend-facing SHARE.txt (also used by watchdog after rotate)
demo_write_share() {
  local URL="${1:?public url required}"
  local ROOT="${DEMO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local DIST="$ROOT/dist"
  local LAN APK_SIZE=""
  LAN=$(demo_detect_lan_ip)
  [[ -f "$DIST/wamu-phone.apk" ]] && APK_SIZE=$(du -h "$DIST/wamu-phone.apk" | awk '{print $1}')

  cat >"$DIST/SHARE.txt" <<EOF
Wamu is running on this PC.

PUBLIC LINK (any network / mobile data):
  App (Chrome):     $URL
  Connect (APK):    $URL/connect
  APK download:     $URL/media-files/wamu-phone.apk

WI-FI (same network as this PC):
  App:              http://${LAN}:8000
  APK:              http://${LAN}:8088/wamu-phone.apk
  USB copy:         $DIST/wamu-phone.apk ${APK_SIZE:+($APK_SIZE)}

LOGIN: use any phone number + OTP 123456 (mock)

Keep this PC awake. Stop with: ./stop_wamu.sh
EOF
}
