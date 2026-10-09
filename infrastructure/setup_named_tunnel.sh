#!/usr/bin/env bash
# One-time: Cloudflare named tunnel → fixed https://wamu-demo.<your-domain> (or CF subdomain).
# Requires a free Cloudflare account. Quick tunnels keep changing; named tunnels do not.
#
# Usage:
#   ./infrastructure/setup_named_tunnel.sh
#   ./infrastructure/setup_named_tunnel.sh --hostname demo.example.com
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CF="$ROOT/.tools/cloudflared"
DIST="$ROOT/dist"
CFG_DIR="$HOME/.cloudflared"
TUNNEL_NAME="${WAMU_TUNNEL_NAME:-wamu-demo}"
HOSTNAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname) HOSTNAME="${2:-}"; shift 2 ;;
    --name) TUNNEL_NAME="${2:-}"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -x "$CF" ]] || { echo "missing $CF" >&2; exit 1; }
mkdir -p "$DIST" "$CFG_DIR"

if [[ ! -f "$CFG_DIR/cert.pem" ]]; then
  echo "[named-tunnel] Opening Cloudflare login in browser…"
  echo "            Complete login, then re-run this script."
  "$CF" tunnel login
fi

if ! "$CF" tunnel list 2>/dev/null | grep -q "$TUNNEL_NAME"; then
  echo "[named-tunnel] Creating tunnel $TUNNEL_NAME…"
  "$CF" tunnel create "$TUNNEL_NAME"
fi

TUNNEL_ID=$("$CF" tunnel list -o json 2>/dev/null | python3 -c "
import json,sys
rows=json.load(sys.stdin)
for r in rows:
  if r.get('name')=='$TUNNEL_NAME':
    print(r['id']); break
" 2>/dev/null || true)

if [[ -z "${TUNNEL_ID:-}" ]]; then
  # fallback parse table
  TUNNEL_ID=$("$CF" tunnel list 2>/dev/null | awk -v n="$TUNNEL_NAME" '$1==n || $2==n {print $1; exit}')
fi
[[ -n "${TUNNEL_ID:-}" ]] || { echo "Could not resolve tunnel id for $TUNNEL_NAME" >&2; exit 1; }

CREDS="$CFG_DIR/${TUNNEL_ID}.json"
CONFIG="$DIST/cloudflared-named.yml"

if [[ -z "$HOSTNAME" ]]; then
  echo
  echo "Enter a hostname you control in Cloudflare DNS (e.g. wamu-demo.example.com)"
  echo "Or create a free *.trycloudflare.com named route via Zero Trust dashboard."
  read -r -p "Hostname: " HOSTNAME
fi
[[ -n "$HOSTNAME" ]] || { echo "hostname required" >&2; exit 1; }

cat >"$CONFIG" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CREDS}
ingress:
  - hostname: ${HOSTNAME}
    service: http://127.0.0.1:8000
  - service: http_status:404
EOF

echo "[named-tunnel] Routing DNS ${HOSTNAME} → tunnel…"
"$CF" tunnel route dns "$TUNNEL_NAME" "$HOSTNAME" || true

echo "https://${HOSTNAME}" >"$DIST/NAMED_TUNNEL_URL.txt"
echo "$CONFIG" >"$DIST/NAMED_TUNNEL_CONFIG.txt"

cat >"$DIST/NAMED_TUNNEL.md" <<EOF
# Named tunnel

- Tunnel: \`${TUNNEL_NAME}\` (\`${TUNNEL_ID}\`)
- URL: https://${HOSTNAME}
- Config: ${CONFIG}

Start API, then:

\`\`\`bash
./infrastructure/phone_demo_up.sh
\`\`\`

\`phone_demo_up.sh\` prefers \`dist/NAMED_TUNNEL_URL.txt\` when the named tunnel process is healthy.
EOF

echo
echo "[named-tunnel] Done. Fixed URL: https://${HOSTNAME}"
echo "              Config: $CONFIG"
echo "              Next: ./infrastructure/phone_demo_up.sh"
