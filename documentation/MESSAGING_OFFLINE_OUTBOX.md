# WAMU Messaging — Offline Outbox & Local Cache

**Status:** Beta Phase 1 (Chrome + device secure storage).  
**Goal:** Don’t lose chat when MTN/Airtel data drops mid-send.

## Pipeline

```
COMPOSED → QUEUED → SENDING → SENT | FAILED
MEDIA    → UPLOADING → SENT | FAILED (retry on reconnect)
THREAD   → local cache (last 200 msgs) shown if API offline
```

## What exists

| Piece | Location |
|-------|----------|
| KvStore interface | `lib/core/storage/kv_store.dart` |
| SQLCipher Drift (native) | `chat_kv_open_io.dart` → `wamu_chat_local.db` |
| Secure storage (web / fallback) | `chat_kv_open_web.dart` / `SecureKvStore` |
| Text outbox | `message_outbox.dart` via `fromKv` |
| Media outbox | `media_outbox.dart` — meta in KvStore; **disk** bytes on IO |
| Thread cache | `local_message_cache.dart` |
| Flush on reconnect | `outbox_flush_provider.dart` |
| Server idempotency | `client_message_id` |
| Staging boot | `scripts/entrypoint.sh` + `docker-compose.staging.yml` |

## Drift / SQLCipher

Native apps open an encrypted Drift DB via **SQLite3MultipleCiphers** (`hooks.user_defines.sqlite3.source: sqlite3mc` + `PRAGMA key`).  
Passphrase lives in secure storage (`wamu_chat_db_key_v1`).  
One-shot migration copies legacy outbox JSON keys from secure storage into Drift.  
Web / Chrome demos keep using secure storage — same `KvStore` API.  
(If cipher hooks fail to load, runtime falls back to `SecureKvStore`.)

## Still later

- Full conversation list offline  
- E2EE private DMs  

## Rule

Server is **not** the only source of truth for composed messages or recent threads.
