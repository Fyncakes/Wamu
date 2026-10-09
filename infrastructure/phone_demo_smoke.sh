#!/usr/bin/env bash
# Demo-ready smoke: public URL + Flutter web + Discover videos + media + auth surfaces.
# Usage:
#   ./infrastructure/phone_demo_smoke.sh
#   ./infrastructure/phone_demo_smoke.sh https://….trycloudflare.com
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE_URL="${1:-}"
if [[ -z "$BASE_URL" ]]; then
  BASE_URL="$(cat "$ROOT/dist/DEMO_URL.txt" 2>/dev/null || true)"
fi
if [[ -z "$BASE_URL" ]]; then
  BASE_URL="http://127.0.0.1:8000"
fi
BASE_URL="${BASE_URL%/}"
API="$BASE_URL/api/v1"
PHONE="+256700000003"
OTP="123456"
PASS=0
FAIL=0

ok() { echo "  OK  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1 — $2"; FAIL=$((FAIL + 1)); }

echo "=== Demo smoke against $BASE_URL ==="

# 1) Public health
HCODE=$(curl -sS -m 20 -o /tmp/wamu_smoke_health.json -w '%{http_code}' "$API/health" || echo 000)
if [[ "$HCODE" == "200" ]]; then ok "api health"; else bad "api health" "$HCODE"; fi

# 2) Flutter web shell
ROOT_BODY=$(curl -sS -m 20 "$BASE_URL/" || true)
if echo "$ROOT_BODY" | grep -qiE '<!doctype html>|<html|Loading Wamu|flutter'; then
  ok "flutter web /"
else
  bad "flutter web /" "not HTML"
fi

# 3) Auth
REQ=$(curl -sS -m 25 -w '\n%{http_code}' -X POST "$API/auth/request-otp" \
  -H 'Content-Type: application/json' -d "{\"phone\":\"$PHONE\"}" || true)
RCODE=$(echo "$REQ" | tail -1)
if [[ "$RCODE" == "200" ]]; then ok "request-otp"; else bad "request-otp" "$RCODE"; fi

VER=$(curl -sS -m 25 -w '\n%{http_code}' -X POST "$API/auth/verify-otp" \
  -H 'Content-Type: application/json' -d "{\"phone\":\"$PHONE\",\"code\":\"$OTP\"}" || true)
VCODE=$(echo "$VER" | tail -1)
VBODY=$(echo "$VER" | sed '$d')
TOKEN=$(echo "$VBODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)
if [[ "$VCODE" == "200" && -n "$TOKEN" ]]; then ok "verify-otp"; else bad "verify-otp" "$VCODE"; fi
AUTH="Authorization: Bearer $TOKEN"

# 4) Discover feed
DISC=$(curl -sS -m 45 -w '\n%{http_code}' -H "$AUTH" "$API/discover/videos?limit=6" || true)
DCODE=$(echo "$DISC" | tail -1)
DBODY=$(echo "$DISC" | sed '$d')
COUNT=$(echo "$DBODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else 0)" 2>/dev/null || echo 0)
if [[ "$DCODE" == "200" && "$COUNT" -ge 1 ]]; then
  ok "discover/videos ($COUNT)"
else
  bad "discover/videos" "$DCODE count=$COUNT"
fi

VIDEO_URL=$(echo "$DBODY" | python3 -c "
import sys,json
from urllib.parse import urljoin
d=json.load(sys.stdin)
if not isinstance(d,list) or not d:
  raise SystemExit
u=d[0].get('video_url') or ''
print(urljoin('$BASE_URL/', u))
" 2>/dev/null || true)
POSTER_URL=$(echo "$DBODY" | python3 -c "
import sys,json
from urllib.parse import urljoin
d=json.load(sys.stdin)
if not isinstance(d,list) or not d: raise SystemExit
u=d[0].get('poster_url') or ''
if u: print(urljoin('$BASE_URL/', u))
" 2>/dev/null || true)

# 5) First video: ranged GET (fast first-play signal)
if [[ -n "${VIDEO_URL:-}" ]]; then
  VCODE=$(curl -sS -m 30 -r 0-65535 -o /dev/null -w '%{http_code}' "$VIDEO_URL" || echo 000)
  if [[ "$VCODE" == "206" || "$VCODE" == "200" ]]; then
    ok "video range ($VCODE)"
  else
    bad "video range" "$VCODE $VIDEO_URL"
  fi
else
  bad "video url" "missing from feed"
fi

# 6) Poster (if present)
if [[ -n "${POSTER_URL:-}" ]]; then
  PCODE=$(curl -sS -m 20 -o /dev/null -w '%{http_code}' "$POSTER_URL" || echo 000)
  if [[ "$PCODE" == "200" ]]; then ok "poster"; else bad "poster" "$PCODE"; fi
else
  ok "poster (none on first clip — skipped)"
fi

# 7) Core commerce surfaces
for path in "/businesses" "/products" "/orders"; do
  C=$(curl -sS -m 25 -o /dev/null -w '%{http_code}' -H "$AUTH" "$API$path" || echo 000)
  if [[ "$C" == "200" ]]; then ok "$path"; else bad "$path" "$C"; fi
done

echo
echo "=== Result: $PASS passed, $FAIL failed ==="
echo "Open on phone: $BASE_URL  (OTP $OTP)"
[[ "$FAIL" -eq 0 ]]
