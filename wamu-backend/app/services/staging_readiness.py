"""Staging / ops readiness — booleans only, never echo secrets."""

from __future__ import annotations

from typing import Any

from app.core.config import Settings, get_settings


def _set(value: str | None) -> bool:
    return bool((value or "").strip())


def _split_urls(raw: str) -> list[str]:
    return [u.strip() for u in (raw or "").split(",") if u.strip()]


def _ice_servers_from(settings: Settings) -> list[dict]:
    servers: list[dict] = []
    stun = _split_urls(settings.stun_urls) or [
        "stun:stun.l.google.com:19302",
        "stun:stun1.l.google.com:19302",
    ]
    for url in stun:
        servers.append({"urls": url})
    turn_urls = _split_urls(settings.turn_urls)
    if turn_urls and settings.turn_username and settings.turn_credential:
        for url in turn_urls:
            servers.append(
                {
                    "urls": url,
                    "username": settings.turn_username,
                    "credential": settings.turn_credential,
                }
            )
    return servers


def _turn_urls_look_local(turn_urls: str) -> bool:
    raw = (turn_urls or "").lower()
    if not raw.strip():
        return False
    markers = ("127.0.0.1", "localhost", "0.0.0.0", "[::1]", "turn:127.")
    return any(m in raw for m in markers)


def rails_readiness(settings: Settings | None = None) -> dict[str, Any]:
    """
    What payment / push / WebRTC rails are configured.

    Safe to expose on /health/rails — no secret values.
    """
    from app.integrations.payments.disbursement import (
        airtel_disbursement_configured,
        mtn_disbursement_configured,
    )

    s = settings or get_settings()
    mtn = _set(s.mtn_subscription_key) and _set(s.mtn_api_user) and _set(s.mtn_api_key)
    airtel = _set(s.airtel_client_id) and _set(s.airtel_client_secret)
    mtn_disb = mtn_disbursement_configured(s)
    airtel_disb = airtel_disbursement_configured(s)
    sms = _set(s.africastalking_username) and _set(s.africastalking_api_key)
    turn = _set(s.turn_urls) and _set(s.turn_username) and _set(s.turn_credential)
    ice = _ice_servers_from(s)
    has_turn_in_ice = any(
        "turn:" in str(entry.get("urls", "")).lower()
        or "turns:" in str(entry.get("urls", "")).lower()
        for entry in ice
    )
    turn_local = _turn_urls_look_local(s.turn_urls)
    api_base = (s.public_api_base or "").rstrip("/")
    callback_reachable = bool(api_base) and not any(
        x in api_base for x in ("127.0.0.1", "localhost", "0.0.0.0")
    )
    webhook_ok = _set(s.payment_webhook_secret) and s.payment_webhook_secret not in {
        "",
        "dev-webhook-secret-change-me",
    }

    return {
        "environment": s.environment,
        "payment_mock_auto_success": s.payment_mock_auto_success,
        "platform_fee_bps": s.platform_fee_bps,
        "payout_auto_execute": s.payout_auto_execute,
        "provider_fee_bps": s.provider_fee_bps,
        "public_api_base_set": bool(api_base),
        "disbursement_callback_reachable": callback_reachable,
        "mtn_collections_configured": mtn,
        "mtn_disbursement_configured": mtn_disb,
        "mtn_disbursement_uses_dedicated_keys": bool(
            s.mtn_disbursement_subscription_key
            or s.mtn_disbursement_api_user
            or s.mtn_disbursement_api_key
        ),
        "airtel_collections_configured": airtel,
        "airtel_disbursement_configured": airtel_disb,
        "airtel_disbursement_pin_set": _set(s.airtel_disbursement_pin),
        "payment_webhook_secret_set": webhook_ok,
        "fcm_server_key_set": _set(s.fcm_server_key),
        "otp_mock_mode": s.otp_mock_mode,
        "payment_momo_otp": bool(getattr(s, "payment_momo_otp_enabled", True)),
        "sms_provider_configured": sms,
        "ready_for_live_otp": (not s.otp_mock_mode) and sms,
        "turn_configured": turn,
        "turn_urls_look_local": turn_local,
        "ice_server_count": len(ice),
        "ice_includes_turn": has_turn_in_ice,
        "ready_for_mock_dry_run": True,
        "ready_for_momo_sandbox": mtn
        and not s.payment_mock_auto_success
        and webhook_ok,
        # Collections + disbursement keys + public callback host + mock off
        "ready_for_live_disbursement": (
            not s.payment_mock_auto_success
            and webhook_ok
            and callback_reachable
            and (mtn_disb or airtel_disb)
        ),
        # Phones need a non-loopback TURN host + matching coturn external-ip
        "ready_for_carrier_calls": turn and has_turn_in_ice and not turn_local,
    }
