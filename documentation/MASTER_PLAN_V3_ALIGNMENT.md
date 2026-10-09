# Wamu Unified Master Project Plan v3 — Engineering Alignment

**Source of truth:** `Wamu_Unified_Master_Project_Plan_v3.docx` (September 2026)

**Superseded for product direction:** Demo Spec video-first / Wamu Move shell, and any “theatrical demo story” (Sarah / Mama Grace / Ronald).

## Product definition

Wamu is a social-economic network whose **execution backbone is trusted local commerce**:

```
Discover (nearby shops/catalog) → Chat → Buy → Pay → Deliver → Review
```

Social chat, communities, short-video discovery, and passenger mobility are **secondary surfaces**, not the MVP home tab.

## What we build now (MVP / Phase 0–1)

| Area | Priority | App stance |
|------|----------|------------|
| Identity (phone OTP, session) | P0 | Keep |
| Customer nearby merchants + categories + product detail | P0 | Shops secondary; home = Videos |

| Merchant onboarding + catalog | P0 | Business owner hub |
| Transactional merchant/order chat | P0 | Chats tab + ORDER_CARD |
| Order state machine | P0 | Orders tab |
| Payments (MTN first, then Airtel) | P0 | MoMo checkout |
| Delivery + rider network | P0 | Assign on paid delivery |
| Ratings | P0 | Business reviews after deliver |
| Admin verify / disputes | P0 | Admin app |
| Analytics basics | P1 | Admin counts + status histograms |

## Thin MVP shipped (Phases 3–5)

Commerce Phase 0–1 loop stays primary; shell home is now **short-video Discover** with Chat-to-Order. Phases 3–5 thin MVPs:

| Phase | Surface | Status |
|-------|---------|--------|
| 3 — Short-video Discover | **Home tab**; merchant Shop videos; like/view/follow | **thin MVP done (home)** |
| 4 — Communities | Join → GROUP chat; leave API; Open chat / Leave UX | **thin MVP done** |
| 5 — Passenger rides | `POST/GET/PATCH /rides`; auto-assign; Flutter `/rides`; workbench ride strip | **thin MVP done** |


Still deferred: video-as-home-tab, comments/ML ranking, community admin moderation, full Uber (surge/maps SDK), **COD** (MoMo-first).

## What we intentionally defer

Per Master Plan §23 / roadmap:

- General WhatsApp-replacement social chat as primary
- Short-video TikTok-style feed **as home** (Phase 3 home-tab upgrade)
- Full passenger mobility Uber clone (maps SDK, surge, multi-stop)
- Community admin moderation dashboard
- Nationwide delivery day one; ML recommendations; microservices/K8s
- **COD / cash on delivery** (MoMo-first)

## Shell (Flutter)

| Tab | Route | Purpose |
|-----|-------|---------|
| Videos | `/home` | Short-video Discover + Chat-to-Order |
| Chats | `/chats` | Transactional merchant chat |
| Orders | `/orders` | Buy → Pay → Deliver → Review |
| You | `/settings` | Profile, roles, merchant + rider entry |

Secondary: `/shops` nearby catalog · `/deliveries` rider workbench · `/business-owner/*` · `/rides` · Communities

## Commerce loop readiness (post-demo realignment)

| Slice | Status |
|-------|--------|
| Nearby shops (`lat`/`lng`/`radius_km`) | done |
| Merchant create with Kampala coords + `owns_business` | done |
| Home empty → Sell on Wamu | done |
| Merchant reject/cancel order | done |
| Rider enroll + my deliveries + advance FSM | done |
| Open delivery claim + auto-assign on enroll | done |
| Kampala area picker for nearby | done |
| In-order business + rider review | done |
| Merchant pending verification banner | done |
| Proof of delivery note on complete | done (API + rider UI + smoke) |
| ORDER_CARD clears Pay after MoMo | done |
| Merchant ORDER_PAID notification | done (+ conversation_id deeplink) |
| Stock commit on pay / restock cancel | done |
| Delivery/fulfill SYSTEM lines in chat | done |
| MoMo PENDING client poll (`/payments/{id}/refresh`) | done |
| Live order/delivery tracking (Orders tab) | done |
| Device GPS nearby shops (area picker fallback) | done |
| Merchant Manage orders live poll + paid snackbar | done |
| Rider workbench live poll | done |
| Shell commerce notif snackbar + Orders badge | done |
| Merchant manage-orders delivery line | done |
| Order disputes (customer open + admin refund/reject) | done |
| Admin analytics (orders/payments by status) | done |
| Chat ORDER_CARD MTN/Airtel picker | done |
| Admin verify → BUSINESS_VERIFIED notify | done |
| Admin payments reconcile button | done |
| Smoke: payout + verify + dispute resolve | done |
| Merchant cancel PAID → restock + mock refund | done |
| Orders retry MTN/Airtel picker | done |
| Cart DELIVERY address client gate | done |
| verify_deploy runs full commerce smoke | done |
| Payout REVERSED on cancel / dispute refund | done |
| Order cancel → delivery CANCELLED | done |
| Alembic CI/docs head = 0013_rider_verification | done |
| FCM foreground → commerce inbox refresh | done |
| Admin health rails panel (`/health/rails`) | done |
| Discover videos (upload + feed + follow) | thin MVP done |
| Communities join/leave + Open chat | thin MVP done |
| Passenger rides FSM + Flutter `/rides` | thin MVP done |
| Rider KYC verification (docs + AI signals + admin queue + audit) | done |
| COD / cash on delivery | deferred (MoMo-first) |

## Remaining road (honest)

### Commerce MVP software — **complete for Master Plan Phase 0–1**

The Discover → Chat → Buy → Pay → Deliver → Review → Dispute loop is implemented, tested, and smoked. Remaining product work for “complete MVP software” is **not** more features — it is **live carrier rails + a Kampala concierge pilot**.

Rider onboarding now includes full KYC (ID / licence / moto / insurance / selfie), Wamu AI *signals* (not government proof), admin approve / re-upload / reject / suspend, and audit logs. Authorized government verification remains a future integration hook (`government_verification: NOT_CONNECTED`).

### Still required before private beta feels real (ops / keys)

| Gate | What | Status |
|------|------|--------|
| Staging compose | `./infrastructure/staging_up.sh` + `verify_deploy.sh` | Scripts ready |
| Live SMS OTP | `AFRICASTALKING_*`, `OTP_MOCK_MODE=false` | Code ready — needs keys |
| MoMo sandbox | `MTN_*` / `AIRTEL_*`, mocks off, webhooks | Adapters ready — needs keys |
| FCM on devices | `flutterfire configure` + `FCM_SERVER_KEY` | Soft-wire done — needs Firebase project |
| Concierge pilot | Real merchants/riders/orders in Kampala beachhead | Ops, not code |

### Intentionally later (beyond thin Phases 3–5)

- Video as home tab / comments / share graph
- Community admin moderation
- Full Uber (surge, maps SDK, multi-stop)
- COD / cash on delivery
- Nationwide delivery, ML recommendations, B2B, microservices/K8s
- Signal E2EE, Mini Apps, custodial wallet

### Soft polish (optional, not MVP blockers)

- ~~Shared MoMo provider widget (cart / chat / orders still duplicate segments)~~ **done** (`MomoProviderPicker`)
- Live MTN/Airtel **refund** & disbursement **reverse** APIs — ledger + mock done; live rails still ops/manual, now audited as `PAYMENT_MANUAL_REFUND_REQUIRED`
- PostGIS nearby (current radius query is enough for pilot)
- Deeper analytics event stream beyond admin histograms

**Rule:** Pilot ops (OTP + MoMo + FCM on real devices) still gate private beta; thin Phases 3–5 are already shipped as secondary surfaces.

## Verification

```bash
# Phase / commerce API tests
cd wamu-backend && pytest -q \
  tests/test_discover_videos.py \
  tests/test_status_channels.py \
  tests/test_passenger_rides.py \
  tests/test_delivery_claim.py \
  tests/test_reviews.py \
  tests/test_order_dispute.py

# Live commerce loop (API must be up, mock OTP/MoMo OK)
python -m scripts.smoke_commerce_loop --base http://127.0.0.1:8000
```

Expected smoke: create shop → nearby → product → order → enroll rider → pay → payout → auto-assign → PoD deliver → review → dispute open → admin verify + resolve → **passenger ride ACCEPTED (201)**.

## Backend bootstrap

`scripts/bootstrap.py` seeds **categories + admin only**. No demo personas, no seed videos, no social theater DMs.

Merchants and riders onboard through the product (or concierge ops), matching Phase 0.

## Kampala beachhead

Food and groceries first. Nearby listing uses **device GPS** when permitted (`geolocator`), with Kampala area chips as fallback (Greater Kampala / Ntinda / Nakawa / …). Default radius for GPS is 8 km.

## North star (MVP)

Completed deliveries per day + order completion rate → evolve toward useful economic activity as the platform matures.
