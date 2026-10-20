# Merchant KYC (for later compliance)

In-app shop-owner identity collection. **Not** BoU licensing, AML filing, or MoMo business onboarding — those stay outside the product.

## Defaults (safe today)

| Flag | Default |
|------|---------|
| `kyc.merchants.enabled` | `false` |
| `kyc.merchants.require_verified_for_payout` | `false` |
| `kyc.merchants.require_verified_for_catalog` | `false` |
| `kyc.riders.enforce_online` | `true` (existing rider KYC) |
| `kyc.buyers.enabled` | `false` (reserved) |

Owners can still submit NIN + ID / selfie / premises photos now. Enforcement only applies when you flip the flags in admin.

## When you are ready

1. Admin → `PUT /api/v1/admin/settings/kyc`  
   ```json
   { "merchants": { "enabled": true, "require_verified_for_payout": true } }
   ```
2. Merchants use **Shop verification (KYC)** in the app (or reopen unfinished drafts).
3. Admin → Businesses → **KYC docs queue** → Review KYC → Approve.
4. Optional later: `require_verified_for_catalog=true` so only verified shops appear in the catalog.

## APIs

- `GET /api/v1/config/kyc` — policy snapshot for clients  
- Owner: `POST …/businesses/{id}/kyc/register|documents|submit`, `GET …/kyc`  
- Admin: `GET …/admin/businesses/kyc-queue`, `GET/POST …/kyc`, approve / reject / request-reupload  
- Admin: `GET|PUT /api/v1/admin/settings/kyc`

Government / NIRA verification stays `NOT_CONNECTED` until you have authorized access.
