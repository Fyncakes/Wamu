"""ICE server list includes TURN for carrier NAT phones."""

from app.core.config import Settings
from app.services import ice


def test_public_turn_fallback_when_no_private_turn(monkeypatch):
    settings = Settings.model_construct(
        stun_urls="stun:stun.l.google.com:19302",
        turn_urls="",
        turn_username="",
        turn_credential="",
        turn_use_public_fallback=True,
    )
    monkeypatch.setattr(ice, "get_settings", lambda: settings)
    servers = ice.build_ice_servers()
    assert any("stun:" in str(s.get("urls")) for s in servers)
    assert any("turn:" in str(s.get("urls")).lower() for s in servers)


def test_private_turn_preferred(monkeypatch):
    settings = Settings.model_construct(
        stun_urls="stun:stun.l.google.com:19302",
        turn_urls="turn:turn.example.com:3478",
        turn_username="wamu",
        turn_credential="secret",
        turn_use_public_fallback=True,
    )
    monkeypatch.setattr(ice, "get_settings", lambda: settings)
    servers = ice.build_ice_servers()
    turn = [s for s in servers if "turn.example.com" in str(s.get("urls"))]
    assert len(turn) == 1
    assert turn[0]["username"] == "wamu"
    assert not any("openrelay" in str(s.get("urls")) for s in servers)
