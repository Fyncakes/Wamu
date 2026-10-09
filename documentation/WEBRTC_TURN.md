# WebRTC calls & TURN (Uganda MTN / Airtel)

**Signaling** is already in-app (REST call lifecycle + WS SDP/ICE). Media is P2P WebRTC.

## ICE servers

Call create / get / accept / history responses include `ice_servers`:

```json
"ice_servers": [
  { "urls": "stun:stun.l.google.com:19302" },
  {
    "urls": "turn:turn.example:3478?transport=udp",
    "username": "wamu",
    "credential": "…"
  }
]
```

| Env | Role |
|-----|------|
| `STUN_URLS` | Comma-separated STUN (defaults to Google) |
| `TURN_URLS` | Comma-separated `turn:` / `turns:` URIs — empty = STUN only |
| `TURN_USERNAME` / `TURN_CREDENTIAL` | Static coturn user (required with `TURN_URLS`) |
| `TURN_EXTERNAL_IP` | Host IP advertised in relay candidates (must match phone-reachable host) |

Flutter `ActiveCallScreen` uses API `ice_servers`; falls back to Google STUN if missing.

## Staging coturn (one-shot)

```bash
cd wamu-backend && source .venv/bin/activate
python -m scripts.print_turn_env
# Paste TURN_* lines into infrastructure/.env.staging

cd ..
docker compose -f infrastructure/docker-compose.staging.yml \
  --env-file infrastructure/.env.staging \
  --profile turn up -d --build

curl -s http://127.0.0.1:8000/api/v1/health/rails | jq \
  '{turn_configured, turn_urls_look_local, ice_includes_turn, ready_for_carrier_calls}'
# ready_for_carrier_calls should be true (non-loopback TURN_URLS + credentials)
```

`TURN_EXTERNAL_IP` is passed into coturn so Docker does not hand out unreachable container IPs.

Without `--profile turn`, stack stays STUN-only (same Wi‑Fi / desktop demos still work).

### Phone test checklist

1. Laptop/server and phones on a path that can reach `TURN_EXTERNAL_IP:3478` (UDP+TCP) and relay ports `49160–49200/udp`  
2. API `TURN_URLS` uses that same IP (not `127.0.0.1`)  
3. Place a 1:1 call on MTN↔Airtel or mobile↔Wi‑Fi — audio should latch via relay if P2P fails  

## Why TURN matters

MTN and Airtel often put handsets behind CGNAT / symmetric NAT. STUN alone fails on many mobile↔mobile calls; TURN relays media through a reachable host.

## Non-goals (yet)

- Time-limited (HMAC) coturn credentials  
- TLS TURN (`turns:`) with certs  
- SFU / group calls  
