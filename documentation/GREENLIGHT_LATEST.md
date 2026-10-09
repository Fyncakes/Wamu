# Wamu green-light report

- When: 2026-10-09T17:09:53+03:00
- Target: `https://fathers-latinas-specializing-accordance.trycloudflare.com`
- Result: **28 green**, **0 red**, **0 skipped**

| Status | Area | Detail |
|--------|------|--------|
| GREEN | Health | API up (otp_mock=True payment_mock=True) |
| GREEN | Flutter web | index served |
| GREEN | Auth OTP (customer) | token issued |
| GREEN | Auth OTP (merchant) | token issued |
| GREEN | Profile | PATCH ok |
| GREEN | Businesses list | 200 |
| GREEN | Products list | 200 |
| GREEN | Categories | 200 |
| GREEN | Discover feed | video=e4c727ef-1d2a-4cf9-9237-9e11158eb35e |
| GREEN | Video streaming | range 206 |
| GREEN | Video view | recorded |
| GREEN | Video like | ok |
| GREEN | Video unlike | ok |
| GREEN | Follow shop | ok |
| GREEN | Merchant My Videos | list ok |
| GREEN | Chat inbox | 200 |
| GREEN | Orders list | 200 |
| GREEN | Checkout create | order=5a2b7b6f-82d7-4394-9634-1bafbeda9f23 |
| GREEN | MoMo mock pay | status=SUCCESS id=5681d9eb-9d80-4009-87d3-e86a239756a1 |
| GREEN | Payment refresh | already SUCCESS |
| GREEN | Notifications | 200 |
| GREEN | Favorites | 200 |
| GREEN | Search | 200 |
| GREEN | Status feed | 200 |
| GREEN | Communities | 200 |
| GREEN | Deliveries open | HTTP 403 |
| GREEN | Rides list | 200 |
| GREEN | Media upload | url=https://fathers-latinas-specializing-accordance.trycloudflar |

## Production readiness (next)
- Turn off `OTP_MOCK_MODE` + wire Africa's Talking
- Turn off `PAYMENT_MOCK_AUTO_SUCCESS` + MTN/Airtel sandbox credentials
- Enable `S3_ENABLED` (MinIO/S3) for media
- Named Cloudflare tunnel or real staging domain
- Run `pytest` + this script in CI against staging
