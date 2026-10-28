"""Build WebRTC ICE server lists for Flutter / browser peers."""

from __future__ import annotations

from app.core.config import get_settings

# Public Metered OpenRelay — unblocks MTN/Airtel CGNAT when no private coturn is set.
# Replace with TURN_URLS + credentials in Railway for production quality / quotas.
_OPENRELAY_TURN: list[dict] = [
    {
        "urls": "turn:openrelay.metered.ca:80",
        "username": "openrelayproject",
        "credential": "openrelayproject",
    },
    {
        "urls": "turn:openrelay.metered.ca:443",
        "username": "openrelayproject",
        "credential": "openrelayproject",
    },
    {
        "urls": "turns:openrelay.metered.ca:443",
        "username": "openrelayproject",
        "credential": "openrelayproject",
    },
]


def _split_urls(raw: str) -> list[str]:
    return [u.strip() for u in (raw or "").split(",") if u.strip()]


def build_ice_servers() -> list[dict]:
    """
    Return WebRTC iceServers entries.

    Always includes STUN (defaults to Google). When TURN_URLS + credentials
    are set, appends those. Otherwise, when turn_use_public_fallback is on,
    appends OpenRelay TURN so carrier-NAT phones can still connect.
    """
    s = get_settings()
    servers: list[dict] = []

    stun = _split_urls(s.stun_urls) or [
        "stun:stun.l.google.com:19302",
        "stun:stun1.l.google.com:19302",
    ]
    for url in stun:
        servers.append({"urls": url})

    turn_urls = _split_urls(s.turn_urls)
    if turn_urls and s.turn_username and s.turn_credential:
        for url in turn_urls:
            servers.append(
                {
                    "urls": url,
                    "username": s.turn_username,
                    "credential": s.turn_credential,
                }
            )
    elif getattr(s, "turn_use_public_fallback", True):
        servers.extend(_OPENRELAY_TURN)

    return servers
