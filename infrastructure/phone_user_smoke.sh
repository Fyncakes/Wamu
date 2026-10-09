#!/usr/bin/env bash
# Simulate a phone user against the live API (local or DEMO_URL / API_URL).
# Usage: ./infrastructure/phone_user_smoke.sh [base_api_url]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="${1:-}"
if [[ -z "$BASE" ]]; then
  BASE="$(cat "$ROOT/dist/API_URL.txt" 2>/dev/null || echo "http://127.0.0.1:8000/api/v1")"
fi
BASE="${BASE%/}"
PHONE="+256700000003"
OTP="123456"
PASS=0
FAIL=0

ok() { echo "  OK  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1 — $2"; FAIL=$((FAIL + 1)); }

echo "=== Phone-user smoke against $BASE ==="

H=$(curl -sf -m 15 "$BASE/health" || true)
if echo "$H" | grep -q '"status"'; then ok "health"; else bad "health" "$H"; fi

# Auth
REQ=$(curl -s -m 20 -w '\n%{http_code}' -X POST "$BASE/auth/request-otp" \
  -H 'Content-Type: application/json' -d "{\"phone\":\"$PHONE\"}")
CODE=$(echo "$REQ" | tail -1)
BODY=$(echo "$REQ" | sed '$d')
if [[ "$CODE" == "200" ]] && echo "$BODY" | grep -q mock_hint; then ok "request-otp"; else bad "request-otp" "$CODE $BODY"; fi

VER=$(curl -s -m 20 -w '\n%{http_code}' -X POST "$BASE/auth/verify-otp" \
  -H 'Content-Type: application/json' -d "{\"phone\":\"$PHONE\",\"code\":\"$OTP\"}")
VCODE=$(echo "$VER" | tail -1)
VBODY=$(echo "$VER" | sed '$d')
TOKEN=$(echo "$VBODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)
if [[ "$VCODE" == "200" && -n "$TOKEN" ]]; then ok "verify-otp"; else bad "verify-otp" "$VCODE $VBODY"; fi

AUTH="Authorization: Bearer $TOKEN"

ME=$(curl -s -m 20 -w '\n%{http_code}' -H "$AUTH" "$BASE/users/me")
MCODE=$(echo "$ME" | tail -1)
MBODY=$(echo "$ME" | sed '$d')
if [[ "$MCODE" == "200" ]] && echo "$MBODY" | grep -q phone; then ok "users/me"; else bad "users/me" "$MCODE $MBODY"; fi

# Ensure profile name so app leaves profile-setup
PROF=$(curl -s -m 20 -w '\n%{http_code}' -X PATCH "$BASE/users/me/profile" \
  -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"first_name":"Amina","last_name":"Demo"}')
PCODE=$(echo "$PROF" | tail -1)
if [[ "$PCODE" == "200" ]]; then ok "profile patch"; else bad "profile patch" "$PCODE $(echo "$PROF" | sed '$d')"; fi

# Common post-login surfaces
for path in \
  "/chat/conversations" \
  "/status" \
  "/businesses" \
  "/products" \
  "/orders" \
  "/notifications"
 do
  R=$(curl -s -m 20 -w '\n%{http_code}' -H "$AUTH" "$BASE$path" || true)
  C=$(echo "$R" | tail -1)
  B=$(echo "$R" | sed '$d')
  if [[ "$C" == "200" ]]; then
    ok "$path"
  else
    bad "$path" "$C $B"
  fi
done

echo
echo "=== Result: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
