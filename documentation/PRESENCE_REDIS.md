# Presence & realtime (multi-instance)

Chat WebSocket presence is shared across API workers via Redis when `REALTIME_USE_REDIS=true`.

## Keys

| Key | Value | TTL |
|-----|--------|-----|
| `wamu:presence:{user_id}` | Active chat-WS socket count | `PRESENCE_TTL_SECONDS` (default **90**) |

`User.last_seen_at` remains in Postgres (updated on connect / `presence.ping`).

## Heartbeat

Flutter sends `{"event":"presence.ping"}` about every 40s. Backend:

1. `EXPIRE` the Redis presence key (keeps online across workers)
2. Updates `last_seen_at`

TTL must stay above the ping interval (90s default).

## Fallback

If Redis is down or `REALTIME_USE_REDIS=false`, presence uses process-local counters (single worker only — fine for local demos).

## Privacy

`show_online` / `show_last_seen` gate both what you **share** and what you **see**
(WhatsApp-style reciprocity), same idea as read receipts:

1. Peer hides → you never see their online / last seen  
2. You hide → you also don’t see peers’ online / last seen  

Applies to inbox `peer_online` / `peer_last_seen_at` and live chat subtitles.

## Env

```bash
REALTIME_USE_REDIS=true
PRESENCE_TTL_SECONDS=90
REDIS_URL=redis://localhost:6379/0
```

Same Redis DB as chat fan-out / rate limits (not the Celery broker DB).
