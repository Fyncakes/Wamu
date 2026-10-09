#!/usr/bin/env bash
# Full functional green-light matrix against DEMO_URL (or local).
# Usage: ./infrastructure/phone_demo_greenlight.sh [base_url]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE_URL="${1:-$(cat "$ROOT/dist/DEMO_URL.txt" 2>/dev/null || echo http://127.0.0.1:8000)}"
BASE_URL="${BASE_URL%/}"
API="$BASE_URL/api/v1"
PHONE_CUSTOMER="+256700000003"
PHONE_MERCHANT="+256700000106"
OTP="123456"
PASS=0
FAIL=0
SKIP=0
REPORT=()

ok() { REPORT+=("GREEN|$1|$2"); echo "  GREEN  $1 — $2"; PASS=$((PASS+1)); }
bad() { REPORT+=("RED|$1|$2"); echo "  RED    $1 — $2"; FAIL=$((FAIL+1)); }
skip() { REPORT+=("SKIP|$1|$2"); echo "  SKIP   $1 — $2"; SKIP=$((SKIP+1)); }

json_get() { python3 -c "import sys,json; d=json.load(sys.stdin); $1" 2>/dev/null; }

http() {
  # http METHOD PATH [json_body] [auth_header]
  local method="$1" path="$2" body="${3:-}" auth="${4:-}"
  local args=(-sS -m 45 -w '\n%{http_code}' -X "$method" "$API$path")
  [[ -n "$auth" ]] && args+=(-H "$auth")
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' -d "$body")
  curl "${args[@]}" 2>/dev/null || printf '\n000'
}

code_of() { echo "$1" | tail -1; }
body_of() { echo "$1" | sed '$d'; }

login() {
  local phone="$1"
  curl -sS -m 25 -X POST "$API/auth/request-otp" -H 'Content-Type: application/json' \
    -d "{\"phone\":\"$phone\"}" >/dev/null || true
  local ver
  ver=$(curl -sS -m 25 -X POST "$API/auth/verify-otp" -H 'Content-Type: application/json' \
    -d "{\"phone\":\"$phone\",\"code\":\"$OTP\"}" || true)
  echo "$ver" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true
}

echo "=== Wamu green-light @ $BASE_URL ==="
echo

# --- 1 Health ---
R=$(http GET /health)
if [[ "$(code_of "$R")" == "200" ]]; then
  BODY=$(body_of "$R")
  MOCK_OTP=$(echo "$BODY" | json_get "print(d.get('otp_mock', d.get('otp_mock_mode', True)))")
  MOCK_PAY=$(echo "$BODY" | json_get "print(d.get('payment_mock', d.get('payment_mock_auto_success', True)))")
  ok "Health" "API up (otp_mock=$MOCK_OTP payment_mock=$MOCK_PAY)"
else
  bad "Health" "HTTP $(code_of "$R")"
fi

# --- 2 Flutter web ---
HTML=$(curl -sS -m 20 "$BASE_URL/" || true)
if echo "$HTML" | grep -qiE '<html|flutter|Loading Wamu'; then
  ok "Flutter web" "index served"
else
  bad "Flutter web" "not HTML"
fi

# --- 3 Auth customer ---
TOK_C=$(login "$PHONE_CUSTOMER")
if [[ -n "$TOK_C" ]]; then ok "Auth OTP (customer)" "token issued"; else bad "Auth OTP (customer)" "no token"; fi
AUTH_C="Authorization: Bearer $TOK_C"

# --- 4 Auth merchant ---
TOK_M=$(login "$PHONE_MERCHANT")
if [[ -n "$TOK_M" ]]; then ok "Auth OTP (merchant)" "token issued"; else bad "Auth OTP (merchant)" "no token"; fi
AUTH_M="Authorization: Bearer $TOK_M"

# --- 5 Profile ---
R=$(http PATCH /users/me/profile '{"first_name":"Amina","last_name":"Tester"}' "$AUTH_C")
[[ "$(code_of "$R")" == "200" ]] && ok "Profile" "PATCH ok" || bad "Profile" "HTTP $(code_of "$R")"

# --- 6 Catalog ---
R=$(http GET /businesses "" "$AUTH_C")
[[ "$(code_of "$R")" == "200" ]] && ok "Businesses list" "200" || bad "Businesses list" "HTTP $(code_of "$R")"
R=$(http GET /products "" "$AUTH_C")
[[ "$(code_of "$R")" == "200" ]] && ok "Products list" "200" || bad "Products list" "HTTP $(code_of "$R")"
R=$(http GET /categories)
[[ "$(code_of "$R")" == "200" ]] && ok "Categories" "200" || bad "Categories" "HTTP $(code_of "$R")"

# --- 7 Discover ---
R=$(http GET '/discover/videos?limit=6' "" "$AUTH_C")
DCODE=$(code_of "$R")
DBODY=$(body_of "$R")
VID=$(echo "$DBODY" | json_get "print(d[0]['id'] if isinstance(d,list) and d else '')")
BIZ=$(echo "$DBODY" | json_get "print(d[0]['business_id'] if isinstance(d,list) and d else '')")
VURL=$(echo "$DBODY" | json_get "
from urllib.parse import urljoin
print(urljoin('$BASE_URL/', d[0]['video_url']) if isinstance(d,list) and d else '')
")
if [[ "$DCODE" == "200" && -n "$VID" ]]; then ok "Discover feed" "video=$VID"; else bad "Discover feed" "HTTP $DCODE"; fi

if [[ -n "$VURL" ]]; then
  VC=$(curl -sS -m 30 -r 0-65535 -o /dev/null -w '%{http_code}' "$VURL" || echo 000)
  [[ "$VC" == "206" || "$VC" == "200" ]] && ok "Video streaming" "range $VC" || bad "Video streaming" "$VC"
else
  bad "Video streaming" "no url"
fi

if [[ -n "$VID" ]]; then
  R=$(http POST "/discover/videos/$VID/view")
  [[ "$(code_of "$R")" == "204" || "$(code_of "$R")" == "200" ]] && ok "Video view" "recorded" || bad "Video view" "HTTP $(code_of "$R")"
  R=$(http POST "/discover/videos/$VID/like" "" "$AUTH_C")
  [[ "$(code_of "$R")" == "200" ]] && ok "Video like" "ok" || bad "Video like" "HTTP $(code_of "$R")"
  R=$(http DELETE "/discover/videos/$VID/like" "" "$AUTH_C")
  [[ "$(code_of "$R")" == "200" ]] && ok "Video unlike" "ok" || bad "Video unlike" "HTTP $(code_of "$R")"
fi
if [[ -n "$BIZ" ]]; then
  R=$(http POST "/discover/businesses/$BIZ/follow" "" "$AUTH_C")
  [[ "$(code_of "$R")" == "201" || "$(code_of "$R")" == "200" ]] && ok "Follow shop" "ok" || bad "Follow shop" "HTTP $(code_of "$R")"
fi

# --- 8 Merchant videos ---
R=$(http GET /businesses/mine "" "$AUTH_M")
MBIZ=$(body_of "$R" | json_get "print(d[0]['id'] if isinstance(d,list) and d else '')")
if [[ -n "$MBIZ" ]]; then
  R=$(http GET "/discover/videos/mine?business_id=$MBIZ" "" "$AUTH_M")
  [[ "$(code_of "$R")" == "200" ]] && ok "Merchant My Videos" "list ok" || bad "Merchant My Videos" "HTTP $(code_of "$R")"
else
  skip "Merchant My Videos" "no business for merchant phone"
fi

# --- 9 Chat ---
R=$(http GET /chat/conversations "" "$AUTH_C")
[[ "$(code_of "$R")" == "200" ]] && ok "Chat inbox" "200" || bad "Chat inbox" "HTTP $(code_of "$R")"

# --- 10 Orders list ---
R=$(http GET /orders "" "$AUTH_C")
[[ "$(code_of "$R")" == "200" ]] && ok "Orders list" "200" || bad "Orders list" "HTTP $(code_of "$R")"

# --- 11 Checkout + mock pay (if product available) ---
PROD=$(curl -sS -m 30 -H "$AUTH_C" "$API/products" | json_get "
items=d if isinstance(d,list) else d.get('items',[])
print(next((p['id'] for p in items if p.get('is_active',True) and p.get('price') is not None), ''))
" 2>/dev/null || true)
PBIZ=$(curl -sS -m 30 -H "$AUTH_C" "$API/products" | json_get "
items=d if isinstance(d,list) else d.get('items',[])
print(next((p.get('business_id','') for p in items if p.get('id')=='$PROD'), ''))
" 2>/dev/null || true)

if [[ -n "$PROD" && -n "$PBIZ" ]]; then
  ORDER_BODY=$(python3 - <<PY
import json
print(json.dumps({
  "business_id": "$PBIZ",
  "items": [{"product_id": "$PROD", "quantity": 1}],
  "fulfillment": "DELIVERY",
  "delivery_address": "Kisaasi, Kampala",
}))
PY
)
  # Try common create shapes
  R=$(http POST /orders "$ORDER_BODY" "$AUTH_C")
  OCODE=$(code_of "$R")
  OBODY=$(body_of "$R")
  OID=$(echo "$OBODY" | json_get "print(d.get('id') or (d.get('order') or {}).get('id') or '')")
  if [[ -z "$OID" ]]; then
    # batch shape
    BATCH=$(python3 - <<PY
import json
print(json.dumps({
  "shops": [{"business_id": "$PBIZ", "items": [{"product_id": "$PROD", "quantity": 1}]}],
  "fulfillment": "DELIVERY",
  "delivery_address": "Kisaasi, Kampala",
}))
PY
)
    R=$(http POST /orders/batch "$BATCH" "$AUTH_C")
    OCODE=$(code_of "$R")
    OBODY=$(body_of "$R")
    OID=$(echo "$OBODY" | json_get "
print(d.get('id') or (d.get('orders') or [{}])[0].get('id') or (d.get('parent_order') or {}).get('id') or '')
")
  fi
  if [[ -n "$OID" ]]; then
    ok "Checkout create" "order=$OID"
    PAY=$(python3 - <<PY
import json, uuid
print(json.dumps({
  "order_id": "$OID",
  "provider": "MTN",
  "phone": "$PHONE_CUSTOMER",
  "idempotency_key": str(uuid.uuid4()),
}))
PY
)
    R=$(http POST /payments "$PAY" "$AUTH_C")
    PCODE=$(code_of "$R")
    PB=$(body_of "$R")
    PID=$(echo "$PB" | json_get "print(d.get('id',''))")
    PSTAT=$(echo "$PB" | json_get "print(d.get('status',''))")
    if [[ "$PCODE" == "200" || "$PCODE" == "201" ]]; then
      ok "MoMo mock pay" "status=$PSTAT id=$PID"
      if [[ -n "$PID" && "$PSTAT" != "SUCCESS" ]]; then
        R=$(http POST "/payments/$PID/refresh" "" "$AUTH_C")
        PSTAT2=$(body_of "$R" | json_get "print(d.get('status',''))")
        [[ "$PSTAT2" == "SUCCESS" || "$(code_of "$R")" == "200" ]] && ok "Payment refresh" "status=$PSTAT2" || bad "Payment refresh" "HTTP $(code_of "$R") $PSTAT2"
      else
        ok "Payment refresh" "already $PSTAT"
      fi
    else
      bad "MoMo mock pay" "HTTP $PCODE $(echo "$PB" | head -c 120)"
    fi
  else
    bad "Checkout create" "HTTP $OCODE $(echo "$OBODY" | head -c 160)"
  fi
else
  skip "Checkout + pay" "no product available"
fi

# --- 12 Notifications / favorites / search ---
R=$(http GET /notifications "" "$AUTH_C")
[[ "$(code_of "$R")" == "200" ]] && ok "Notifications" "200" || bad "Notifications" "HTTP $(code_of "$R")"
R=$(http GET /favorites "" "$AUTH_C")
[[ "$(code_of "$R")" == "200" ]] && ok "Favorites" "200" || bad "Favorites" "HTTP $(code_of "$R")"
R=$(http GET '/search?q=shop' "" "$AUTH_C")
[[ "$(code_of "$R")" == "200" ]] && ok "Search" "200" || bad "Search" "HTTP $(code_of "$R")"

# --- 13 Status / communities ---
R=$(http GET /status "" "$AUTH_C")
[[ "$(code_of "$R")" == "200" ]] && ok "Status feed" "200" || bad "Status feed" "HTTP $(code_of "$R")"
R=$(http GET /communities "" "$AUTH_C")
[[ "$(code_of "$R")" == "200" ]] && ok "Communities" "200" || bad "Communities" "HTTP $(code_of "$R")"

# --- 14 Riders / deliveries / rides ---
R=$(http GET /deliveries/open "" "$AUTH_C")
C=$(code_of "$R")
[[ "$C" == "200" || "$C" == "401" || "$C" == "403" ]] && ok "Deliveries open" "HTTP $C" || bad "Deliveries open" "HTTP $C"
R=$(http GET /rides "" "$AUTH_C")
C=$(code_of "$R")
[[ "$C" == "200" ]] && ok "Rides list" "200" || bad "Rides list" "HTTP $C"

# --- 15 Media upload (tiny png) ---
PNG_B64='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
echo "$PNG_B64" | base64 -d >/tmp/wamu_gl.png
UC=000
for _try in 1 2; do
  UC=$(curl -sS -m 90 -o /tmp/wamu_gl_up.json -w '%{http_code}' -X POST "$API/media/upload" \
    -H "$AUTH_C" -F "file=@/tmp/wamu_gl.png;type=image/png" || echo 000)
  [[ "$UC" == "200" ]] && break
  sleep 1
done
if [[ "$UC" == "200" ]]; then
  UURL=$(python3 -c "import json; print(json.load(open('/tmp/wamu_gl_up.json')).get('url',''))" 2>/dev/null || true)
  ok "Media upload" "url=${UURL:0:60}"
else
  bad "Media upload" "HTTP $UC"
fi

# --- Summary ---
OUT="$ROOT/dist/demo-logs/GREENLIGHT.md"
mkdir -p "$(dirname "$OUT")"
{
  echo "# Wamu green-light report"
  echo
  echo "- When: $(date -Is)"
  echo "- Target: \`$BASE_URL\`"
  echo "- Result: **$PASS green**, **$FAIL red**, **$SKIP skipped**"
  echo
  echo "| Status | Area | Detail |"
  echo "|--------|------|--------|"
  for line in "${REPORT[@]}"; do
    IFS='|' read -r st area detail <<<"$line"
    echo "| $st | $area | $detail |"
  done
  echo
  echo "## Production readiness (next)"
  echo "- Turn off \`OTP_MOCK_MODE\` + wire Africa's Talking"
  echo "- Turn off \`PAYMENT_MOCK_AUTO_SUCCESS\` + MTN/Airtel sandbox credentials"
  echo "- Enable \`S3_ENABLED\` (MinIO/S3) for media"
  echo "- Named Cloudflare tunnel or real staging domain"
  echo "- Run \`pytest\` + this script in CI against staging"
} >"$OUT"

echo
echo "=== Result: $PASS green, $FAIL red, $SKIP skipped ==="
echo "Report: $OUT"
[[ "$FAIL" -eq 0 ]]
