"""ICE / TURN server builder tests."""

from __future__ import annotations

from unittest.mock import patch

from app.services.ice import build_ice_servers


def test_build_ice_servers_stun_only_by_default():
    with patch("app.services.ice.get_settings") as gs:
        gs.return_value.stun_urls = (
            "stun:stun.l.google.com:19302,stun:stun1.l.google.com:19302"
        )
        gs.return_value.turn_urls = ""
        gs.return_value.turn_username = ""
        gs.return_value.turn_credential = ""
        servers = build_ice_servers()
    assert len(servers) == 2
    assert all("credential" not in s for s in servers)
    assert servers[0]["urls"].startswith("stun:")


def test_build_ice_servers_includes_turn_when_configured():
    with patch("app.services.ice.get_settings") as gs:
        gs.return_value.stun_urls = "stun:stun.l.google.com:19302"
        gs.return_value.turn_urls = (
            "turn:turn.wamu.local:3478?transport=udp,"
            "turns:turn.wamu.local:5349?transport=tcp"
        )
        gs.return_value.turn_username = "wamu"
        gs.return_value.turn_credential = "secret"
        servers = build_ice_servers()
    assert len(servers) == 3
    turn = [s for s in servers if s["urls"].startswith("turn")]
    assert len(turn) == 2
    assert turn[0]["username"] == "wamu"
    assert turn[0]["credential"] == "secret"


def test_build_ice_servers_skips_turn_without_credentials():
    with patch("app.services.ice.get_settings") as gs:
        gs.return_value.stun_urls = "stun:stun.l.google.com:19302"
        gs.return_value.turn_urls = "turn:turn.wamu.local:3478"
        gs.return_value.turn_username = ""
        gs.return_value.turn_credential = ""
        servers = build_ice_servers()
    assert len(servers) == 1
    assert "turn" not in servers[0]["urls"]
