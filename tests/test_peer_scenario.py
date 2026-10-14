"""Safety checks for synchronized peer scenario without a live game."""
import pytest
from addon_forge.config import Config
from addon_forge.peer_scenario import peer_scenario, _fixture_env


def test_peer_requires_valid_character_name(tmp_path):
    cfg = Config(wow_dir=tmp_path / "wow", wine_prefix=tmp_path / "wine",
                 realm_dir=tmp_path / "realm")
    with pytest.raises(ValueError, match="2-12"):
        peer_scenario(cfg, character="Unknown 123", approve=True)


def test_peer_defaults_to_read_only_plan(tmp_path):
    cfg = Config(wow_dir=tmp_path / "wow", wine_prefix=tmp_path / "wine",
                 realm_dir=tmp_path / "realm")
    result = peer_scenario(cfg, character="Forgechar")
    assert result["status"] == "plan_only"
    assert "AzerothGhost" in " ".join(result["steps"])


def test_peer_environment_is_local_only_and_no_soft_pass(tmp_path, monkeypatch):
    monkeypatch.setenv("E2E_ALLOW_SOFT_PASS", "1")
    secret = "a" * 64
    env = _fixture_env(secret, 13306, "Forgechar", tmp_path)
    assert "E2E_ALLOW_SOFT_PASS" not in env
    assert env["E2E_AUTH_ADDR"] == "127.0.0.1:3724"
    assert env["E2E_CHAR_DSN"] == f"root:{secret}@tcp(127.0.0.1:13306)/acore_characters"

import json
from addon_forge.peer_scenario import _read_ready


def test_legacy_live_one_peer_handshake(tmp_path):
    path = tmp_path / "ready.json"
    path.write_text(json.dumps({"status": "ready", "name": "Fpeerabc",
                                "target": "Test"}))
    assert _read_ready(path, target="Test", count=1) == ["Fpeerabc"]


def test_versioned_four_peer_handshake(tmp_path):
    path = tmp_path / "ready.json"
    names = ["Fpeeraaa", "Fpeerbbb", "Fpeerccc", "Fpeerddd"]
    path.write_text(json.dumps({"version": 2, "status": "ready", "name": names[0],
                                "names": names, "count": 4, "target": "Test"}))
    assert _read_ready(path, target="Test", count=4) == names


@pytest.mark.parametrize("payload,count", [
    ({"status":"ready","name":"Fpeera","target":"Other"},1),
    ({"version":2,"status":"ready","name":"Fpeera","names":["Fpeera"],"count":2,"target":"Test"},1),
    ({"version":2,"status":"ready","name":"Fpeera","names":["Fpeera","Fpeera"],"count":2,"target":"Test"},2),
    ({"status":"ready","name":"Fpeera","target":"Test"},2),
])
def test_invalid_peer_handshakes_fail_closed(tmp_path, payload, count):
    path = tmp_path / "ready.json"
    path.write_text(json.dumps(payload))
    with pytest.raises(RuntimeError):
        _read_ready(path, target="Test", count=count)


def test_party_lifecycle_preview_requires_multiple_peers(tmp_path):
    cfg = Config(wow_dir=tmp_path / "wow", wine_prefix=tmp_path / "wine",
                 realm_dir=tmp_path / "realm")
    with pytest.raises(ValueError, match="three or four"):
        peer_scenario(cfg, character="Test", lifecycle=True, peers=1)
    plan = peer_scenario(cfg, character="Test", lifecycle=True, peers=3)
    assert plan["status"] == "plan_only"
    assert plan["peers"] == 3
    assert plan["lifecycle"] is True


def test_protocol_party_stage_variables_are_local(tmp_path):
    env = _fixture_env("a" * 64, 13306, "Test", tmp_path, peers=3)
    assert env["FORGE_PEER_COUNT"] == "3"
    assert env["FORGE_PEER_LEAVE"] == str(tmp_path / "request-leave")
    assert env["FORGE_PEER_LEFT"] == str(tmp_path / "left")
