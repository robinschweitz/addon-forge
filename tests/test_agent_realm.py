import json
from pathlib import Path
from types import SimpleNamespace
import pytest

from addon_forge import agent_realm


def test_capabilities_are_honest_about_not_yet_implemented():
    data = agent_realm.capabilities()
    assert "upstream_server_fixtures" in data["available"]
    assert any("multi-player" in x for x in data["in_progress"])


def test_unapproved_realm_scenario_never_invokes_docker(tmp_path, monkeypatch):
    def deny(*args, **kwargs):
        pytest.fail("No subprocess for read-only scenario planning")
    monkeypatch.setattr(agent_realm.subprocess, "run", deny)
    result = agent_realm.run_realm_smoke(tmp_path, scenario="create-character")
    assert result["status"] == "plan_only"
    assert "approve-fixtures" in str(result)


@pytest.mark.parametrize("name", ["", "rm -rf /", "reset-volume", "create-admin"])
def test_unrecognized_scenarios_refused(name, tmp_path):
    with pytest.raises(ValueError, match="Unsupported fixture"):
        agent_realm.run_realm_smoke(tmp_path, scenario=name, approve=True)


def test_fixture_uses_upstream_fixed_go_test_and_redacts_password(tmp_path, monkeypatch):
    root = tmp_path / "ac"
    (root / "e2e").mkdir(parents=True)
    secret = "a" * 64
    monkeypatch.setattr(agent_realm, "_preflight", lambda realm: (secret, 13306))
    called = []
    def executor(argv, **kwargs):
        called.extend(argv)
        assert kwargs["env"]["E2E_CHAR_DSN"] == (
            f"root:{secret}@tcp(127.0.0.1:13306)/acore_characters"
        )
        assert kwargs["env"]["E2E_AUTH_ADDR"] == "127.0.0.1:3724"
        assert "E2E_ALLOW_SOFT_PASS" not in kwargs["env"]
        return SimpleNamespace(returncode=0, stdout=f"PASS secret={secret}", stderr="")
    result = agent_realm.run_realm_smoke(
        root, scenario="create-character", approve=True, executor=executor
    )
    assert result["status"] == "passed"
    assert secret not in str(result)
    assert called[called.index("-run")+1] == "^TestSmoke_FirstTimeCharacterCreate$"
    assert called[called.index("-parallel")+1] == "1"
