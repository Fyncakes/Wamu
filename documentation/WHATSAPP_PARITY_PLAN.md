# Wamu × WhatsApp Screen Recording — UX Gap Plan

**Source:** `specs/WhatsApp Video 2026-09-10 at 14.42.47.mp4` (~96s phone recording)  
**Goal:** Make Wamu messaging feel as habit-forming and attractive as modern WhatsApp — without cloning brand assets — tuned for Uganda youth.

---

## 1. What the video shows (observed)

### Navigation (5 tabs)
| WhatsApp | Role |
|----------|------|
| **Chats** | Inbox home + search + filters + new chat FAB |
| **Updates** | Status cards carousel + **Channels** discovery |
| **Communities** | Community hubs |
| **Calls** | Call history / dial |
| **You** | Profile + deep settings (not a generic Settings dump) |

### Chats inbox polish
- Brand title top-left (“WhatsApp”), overflow menu top-right
- Large pill search: **“Ask Meta AI or Search”**
- Filter chips: **All · Unread · Favourites · Groups** (+ manage)
- Dense list rows: avatar · bold name · rich preview (text / “3 photos” / “Video” / “You reacted 👍…”) · relative time · ✓✓ receipts
- Dual FABs: Meta AI (small) + green **+** new chat (large rounded square)
- Dark charcoal UI, green active pill on bottom nav

### Updates (Status+)
- Horizontal **status story cards** (“My status” first with +)
- **Channels** list + Explore + “Find channels to follow” with Follow CTAs
- Dual FABs: pencil (text status) + camera (media status)

### Conversation thread
- Chat wallpaper doodle pattern
- Reply/quote nested in bubble (green accent bar)
- Reactions stuck on bubble corner
- Media grids (“Forwarded” albums)
- Blue double-ticks on read media
- Soft composer: emoji · “Message” · attachments (implied)

### New chat
- “Select contact” with **contact count**
- Photo or initial-letter colored avatars
- Search + overflow

### You / Profile
- Large avatar + name switcher
- Structured settings with icons + **one-line subtitles** (Privacy, Appearance, Storage & data, Linked devices, Broadcasts, Parental controls…)

---

## 2. Wamu vs WhatsApp (honest gap)

| Area | Wamu today | WhatsApp (video) | Gap |
|------|------------|------------------|-----|
| Bottom nav | Chats · **Updates** · Communities · Calls · **You** | Same five roles | ✅ Sprint 1 |
| Dark shell | OLED messenger default (`messengerDarkTheme`) | Charcoal UI | ✅ Sprint 1 |
| Chats header | **Wamu** + search pill “Ask Wamu or Search” + overflow | Brand + search | ✅ Sprint 1 |
| Filters | All / Unread / Favourites / Groups / Archived | All / Unread / Favourites / Groups | ✅ Sprint 1 |
| List previews | Relative time, media/reaction preview strings, ✓/✓✓ on own last | Richer reaction previews | ✅ Reaction + album “N photos” + media labels |
| FAB | Wamu AI + **+** new chat | Dual FABs | ✅ Sprint 1 |
| You tab | Avatar hub + subtitled rows (Privacy, Appearance, Data saver…) | Identity-first settings | ✅ Sprint 1 |
| Status / Updates | Horizontal **story cards** + Channels (Campus/Cranes/Faith) + Follow | Status + Channels | ✅ Sprint 3 |
| Thread UX | Wallpaper, quotes w/ sender, floating reactions, denser emoji, live READ ✓✓, WA composer order | Wallpaper, quotes, ticks, media grids, emoji tray | ✅ Sprint 2 (core) |
| New chat | Select contact + colored avatars + on-Wamu count + SMS/share invite | Full contact picker polish | ✅ Phase D |
| AI | Ask Wamu from search submit / chip → `/ai` | Search-integrated | ✅ Sprint 1 |

**Already strong on Wamu:** peer DMs, realtime WS, reactions, photos/voice, communities→groups, 1:1 WebRTC calls, data saver, offline outbox — keep these; **dress and deepen** them.

---

## 3. Product principles (do / don’t)

1. **Messenger-first look** — dark OLED theme as default for Chats/Updates/Calls; keep Uganda green as accent (not marketplace sand as the chat chrome).
2. **Thumb-native density** — WhatsApp wins on “scan inbox in 2 seconds”; previews + filters matter more than new backend for attractiveness.
3. **Updates = Status + Channels** — Status alone feels thin; Channels give discovery for youth (campus, football, faith — Uganda-local).
4. **You tab** — profile is identity + privacy + appearance, not a junk drawer.
5. **Don’t clone Meta trademarks** — no WhatsApp logo, doodle pack, or “Meta AI” naming. Use **Wamu AI** / **Ask Wamu**.
6. **Uganda edge** — data saver badge on previews, low-bitrate voice default, local community channels (not US celebs).

---

## 4. Phased plan (recommended)

### Phase A — Visual & inbox parity (1–2 weeks) ← **highest attractiveness ROI**
**Ship:**
1. **Messenger dark theme** for chat shell (Chats/Updates/Calls/Communities/You); green accent `#00A884`-adjacent but own token (e.g. Wamu green `#0B6E4F` → brighter active `#1DAA61`).
2. Chats header: **“Wamu”** wordmark left + overflow; **search pill** “Ask Wamu or Search”.
3. Filter chips: All / Unread / Favourites / Groups.
4. Inbox row upgrade: relative time, media/reaction preview strings, delivery ticks on own last message, group vs DM avatar treatment.
5. FAB: large **+** new chat (rounded square); optional small **Wamu AI** bubble above.
6. Rename **Settings → You**; large avatar header + subtitled list rows (Privacy, Appearance, Data saver, Linked later…).
7. Rename **Status → Updates** in nav (keep Status UI as first section).

**Success:** Side-by-side with the video, a stranger recognizes “modern messenger,” not “marketplace with chat.”

### Phase B — Thread delight (1–2 weeks)
1. Chat wallpaper (subtle Uganda-themed pattern, own art — not WA doodles).
2. **Reply/quote** UI (backend: `reply_to_message_id`).
3. Read receipts ✓ / ✓✓ (wire `status` already on messages).
4. Emoji picker in composer; long-press reaction polish (already partly done).
5. Better media bubble: multi-image grid, caption, “Forwarded” later.
6. Composer chrome: emoji · attach · camera · mic (hold) · send — WhatsApp order.

### Phase C — Updates = Status + Channels (1–2 weeks)
1. Status as **horizontal cards** (“My status” first).
2. Camera + text FABs on Updates.
3. **Channels** section: follow Kampala Campus / Cranes / Faith (can reuse community catalog as broadcast-style channels initially).
4. Explore / Follow CTAs.

### Phase D — Contacts & growth (1 week) ← **✅ Done (2026-09)**
1. Select-contact screen with avatars + count (“N people on Wamu”).
2. Invite-by-SMS for numbers not on Wamu.
3. Favourites / pin / mute / archive (list filters need these).

### Phase E — Trust & polish (ongoing) ← **in progress**
1. Appearance: dark/light/system + chat wallpaper picker. ✅ (Appearance + wallpaper exist)
2. Storage & data: auto-download rules (photos/voice) — Uganda critical. ✅ photos + voice gated; Data saver compresses uploads
3. Presence: online / last seen (privacy toggles). ✅ You → Privacy + WS gated + **reciprocal** (hide yours → don’t see theirs)
4. coturn TURN for real MTN/Airtel calls — ✅ API `ice_servers` + optional staging coturn (`documentation/WEBRTC_TURN.md`); E2EE per blueprint v2 still pending
5. Read-receipts privacy — ✅ You → Privacy toggle; reciprocal mask on 1:1 (groups unchanged)
6. Redis presence — ✅ `wamu:presence:{user_id}` + TTL heartbeat (`documentation/PRESENCE_REDIS.md`)


---

## 5. Suggested sprint order (next 3 sprints)

| Sprint | Focus | User-visible win | Status |
|--------|--------|------------------|--------|
| **S1** | Phase A dark shell + Chats inbox + You tab | “Looks like a real chat app” | ✅ Done |
| **S2** | Phase B thread (quotes, ticks, wallpaper, composer) | “Feels good to chat daily” | ✅ Done |
| **S3** | Phase C Updates/Channels (+ contact picker later in D) | “Something to open besides DMs” | ✅ Done |
| **D** | Contacts & growth (picker + invite SMS) | “Bring friends onto Wamu” | ✅ Done (2026-09) |
| **E** | Storage + presence + TURN + receipts + Redis presence | “Safe on MTN/Airtel + private” | 🟡 E2EE later |

**Decisions locked in code:** dark messenger default for the app shell; nav label **Updates** (path `/status`, alias `/updates`); **You** tab (path `/settings`, alias `/you`).

---

## 6. Explicit non-goals (near term)
- Exact WhatsApp iconography / wallpaper clones  
- Full Channels CMS / creator monetization  
- Linked devices / multi-device sync  
- Parental controls / subscriptions (Broadcasts row shows “coming soon”)
