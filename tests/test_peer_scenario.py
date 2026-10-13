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
