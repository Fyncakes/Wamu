"""ICE / TURN server builder tests."""

from __future__ import annotations

from unittest.mock import patch

from app.services.ice import build_ice_servers


def test_build_ice_servers_uses_public_turn_when_private_unset():
    with patch("app.services.ice.get_settings") as gs:
        gs.return_value.stun_urls = (
            "stun:stun.l.google.com:19302,stun:stun1.l.google.com:19302"
        )
        gs.return_value.turn_urls = ""
        gs.return_value.turn_username = ""
        gs.return_value.turn_credential = ""
        gs.return_value.turn_use_public_fallback = True
        servers = build_ice_servers()
    assert any(str(s.get("urls", "")).startswith("stun:") for s in servers)
    assert any("turn:" in str(s.get("urls", "")).lower() for s in servers)


def test_build_ice_servers_includes_turn_when_configured():
    with patch("app.services.ice.get_settings") as gs:
        gs.return_value.stun_urls = "stun:stun.l.google.com:19302"
        gs.return_value.turn_urls = (
            "turn:turn.wamu.local:3478?transport=udp,"
            "turns:turn.wamu.local:5349?transport=tcp"
        )
        gs.return_value.turn_username = "wamu"
        gs.return_value.turn_credential = "secret"
        gs.return_value.turn_use_public_fallback = True
        servers = build_ice_servers()
    assert len(servers) == 3
    turn = [s for s in servers if s["urls"].startswith("turn")]
    assert len(turn) == 2
    assert turn[0]["username"] == "wamu"
    assert turn[0]["credential"] == "secret"


def test_build_ice_servers_can_disable_public_fallback():
    with patch("app.services.ice.get_settings") as gs:
        gs.return_value.stun_urls = "stun:stun.l.google.com:19302"
        gs.return_value.turn_urls = "turn:turn.wamu.local:3478"
        gs.return_value.turn_username = ""
        gs.return_value.turn_credential = ""
        gs.return_value.turn_use_public_fallback = False
        servers = build_ice_servers()
    assert len(servers) == 1
    assert "turn" not in servers[0]["urls"]
