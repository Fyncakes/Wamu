"""Operator KYC policy flags — defaults keep today's behavior until you flip them.

BoU / AML / MoMo business onboarding remain outside this codebase; these flags only
control in-app document collection and soft enforcement when you are ready.
"""

from __future__ import annotations

from sqlalchemy.ext.asyncio import AsyncSession

from app.services import app_settings as settings_service

# app_settings keys
KEY_RIDERS_ENFORCE_ONLINE = "kyc.riders.enforce_online"
KEY_MERCHANTS_ENABLED = "kyc.merchants.enabled"
KEY_MERCHANTS_REQUIRE_PAYOUT = "kyc.merchants.require_verified_for_payout"
KEY_MERCHANTS_REQUIRE_CATALOG = "kyc.merchants.require_verified_for_catalog"
KEY_BUYERS_ENABLED = "kyc.buyers.enabled"

_TRUE = {"1", "true", "yes", "on"}


def _as_bool(raw: str, default: bool) -> bool:
    if raw is None or str(raw).strip() == "":
        return default
    return str(raw).strip().lower() in _TRUE


async def get_kyc_policy(db: AsyncSession) -> dict:
    """Public/authenticated snapshot for clients + enforcement helpers."""
    riders_enforce = _as_bool(
        await settings_service.get_setting(db, KEY_RIDERS_ENFORCE_ONLINE, "true"),
        True,
    )
    merchants_enabled = _as_bool(
        await settings_service.get_setting(db, KEY_MERCHANTS_ENABLED, "false"),
        False,
    )
    require_payout = _as_bool(
        await settings_service.get_setting(db, KEY_MERCHANTS_REQUIRE_PAYOUT, "false"),
        False,
    )
    require_catalog = _as_bool(
        await settings_service.get_setting(db, KEY_MERCHANTS_REQUIRE_CATALOG, "false"),
        False,
    )
    buyers_enabled = _as_bool(
        await settings_service.get_setting(db, KEY_BUYERS_ENABLED, "false"),
        False,
    )
    return {
        "riders": {
            "enforce_online": riders_enforce,
            "note": "Riders already use full ID/licence KYC; this only toggles go-online gate.",
        },
        "merchants": {
            "enabled": merchants_enabled,
            "require_verified_for_payout": require_payout,
            "require_verified_for_catalog": require_catalog,
            "note": (
                "When enabled, owners can submit NIN + ID docs. "
                "Enforcement flags stay off until you turn them on."
            ),
        },
        "buyers": {
            "enabled": buyers_enabled,
            "note": "Optional buyer identity — not wired yet; reserved for later.",
        },
        "government_verification": {
            "status": "NOT_CONNECTED",
            "note": (
                "In-app AI checks are admin signals only. "
                "NIRA / URA / BoU licensing stay outside this product until authorized."
            ),
        },
    }


async def set_kyc_policy(db: AsyncSession, patch: dict) -> dict:
    """Admin update — only known boolean keys."""
    merchants = patch.get("merchants") or {}
    riders = patch.get("riders") or {}
    buyers = patch.get("buyers") or {}

    mapping = [
        (KEY_RIDERS_ENFORCE_ONLINE, riders.get("enforce_online")),
        (KEY_MERCHANTS_ENABLED, merchants.get("enabled")),
        (KEY_MERCHANTS_REQUIRE_PAYOUT, merchants.get("require_verified_for_payout")),
        (KEY_MERCHANTS_REQUIRE_CATALOG, merchants.get("require_verified_for_catalog")),
        (KEY_BUYERS_ENABLED, buyers.get("enabled")),
    ]
    for key, value in mapping:
        if value is None:
            continue
        await settings_service.set_setting(db, key, "true" if bool(value) else "false")
    return await get_kyc_policy(db)


async def merchants_kyc_enabled(db: AsyncSession) -> bool:
    policy = await get_kyc_policy(db)
    return bool(policy["merchants"]["enabled"])


async def require_merchant_verified_for_payout(db: AsyncSession) -> bool:
    policy = await get_kyc_policy(db)
    m = policy["merchants"]
    return bool(m["enabled"] and m["require_verified_for_payout"])


async def require_merchant_verified_for_catalog(db: AsyncSession) -> bool:
    policy = await get_kyc_policy(db)
    m = policy["merchants"]
    return bool(m["enabled"] and m["require_verified_for_catalog"])
