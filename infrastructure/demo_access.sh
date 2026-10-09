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
# Wamu demo access

Keep the **PC awake**. Quick tunnels change URL when restarted — prefer Wi‑Fi when on the same network.

## Public (any network / mobile data)

- **App:** ${URL}
- **Connect (APK paste):** ${URL}/connect
- **Health:** ${URL}/api/v1/health
- **OTP:** \`123456\`

If Chrome shows Error **1033**, the old tunnel died — open the new URL from this file (or ask for a restart).

## Wi‑Fi fallback (same LAN as PC)

- **App:** http://${LAN}:8000
- **APK download:** http://${LAN}:8088/wamu-phone.apk
- **Connect page:** http://${LAN}:8000/connect

## Native APK

1. Install \`wamu-phone.apk\` (USB, or Wi‑Fi link above).
2. Open app → paste **${URL}/connect** (or the Wi‑Fi connect URL).

## Fixed public URL (optional)

One-time Cloudflare login + named tunnel:

\`\`\`bash
./infrastructure/setup_named_tunnel.sh
\`\`\`

Then \`./infrastructure/phone_demo_up.sh\` will reuse that hostname.

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
