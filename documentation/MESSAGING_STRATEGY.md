# Wamu Messenger — Chat-first strategy

**Positioning:** Uganda’s digital communication home.  
**Loop:** Connect → Chat → Share → Discover → Do more.

## Blueprint takeaways (v1 docx + v2 PDF)

| Topic | Decision we are shipping |
|-------|--------------------------|
| Scope | Messaging first; marketplace/payments/AI are secondary (Discover / Settings) |
| Nav | **Chats \| Status \| Communities \| Calls \| Settings** |
| Realtime | FastAPI WebSockets for Phase 1; Go/Centrifugo gateway later (v2) |
| Encryption | TLS + auth now; **Signal E2EE in Phase 2** — never invent crypto |
| Media | Client-side compression + data saver; MinIO/S3 with local fallback |
| Calls | WebRTC 1:1 + WS signaling; STUN default + optional coturn TURN (`documentation/WEBRTC_TURN.md`) |
| Youth hooks | Status (24h), reactions, communities, peer DMs, voice/video calls |

## Why not “full WhatsApp in week one”

v2 correctly flags feature creep: E2EE + server media processing + TURN calling + communities as real groups **together** delays a trustworthy Uganda beta. We ship a vertical slice:

`register → find peer by phone → chat realtime → react → photos/voice → post status → browse communities → discover local businesses`

## Shipped media (Phase 3 slice)

- Gallery photos with **data-saver compression** (1280px / 70% when Data saver is on)
- Hold-to-record **voice notes** (AAC ~32kbps mono)
- Upload via `/media/upload` (local disk fallback when MinIO is down)
- Message types: `TEXT` | `IMAGE` | `VOICE`

## Shipped groups (Phase 4 slice)

- Communities **Join** → live `GROUP` conversation (shared per community slug)
- **New group** with +256 member invites
- Seeded **Kampala Campus** group for demo users
- Groups appear in Chats with member count

## Demo accounts (OTP `123456`)

| Phone | Persona |
|-------|---------|
| `+256700000003` | Amina (customer) — has DM with Brian |
| `+256700000004` | Brian Okello (campus youth) |
| `+256700000002` | Business owner |
| `+256700000001` | Admin |

## Next phases (aligned to blueprints)

1. Client E2EE (Signal) + SQLCipher local store  
2. ~~coturn TURN for carrier NAT (MTN/Airtel)~~ ✅ see `documentation/WEBRTC_TURN.md`  
3. ~~FCM push without plaintext body~~ ✅ see `documentation/PUSH_NOTIFICATIONS.md`  
4. Resumable chunked uploads for larger video  
5. Group calls (later)  
