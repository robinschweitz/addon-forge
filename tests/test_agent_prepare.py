"""Preparation never injects credentials or deploys over a live WoW session."""
from pathlib import Path
from unittest.mock import Mock
import pytest

from addon_forge.config import Config
from addon_forge import agent_prepare


def config(tmp_path):
    return Config(wow_dir=tmp_path / "WoW", wine_prefix=tmp_path / "wine")


def test_login_requires_explicit_client_start(tmp_path):
    with pytest.raises(ValueError, match="start-client"):
        agent_prepare.prepare_environment(config(tmp_path), login=True)


def test_prepare_refuses_unmarked_client_on_windows(tmp_path, monkeypatch):
    monkeypatch.setattr(agent_prepare.sys, "platform", "win32")
    with pytest.raises(RuntimeError, match="marked"):
        agent_prepare.prepare_environment(config(tmp_path))


def test_prepare_does_not_deploy_while_game_open(tmp_path, monkeypatch):
    from addon_forge import windows_client
    from addon_forge import win_login
    monkeypatch.setattr(agent_prepare.sys, "platform", "win32")
    monkeypatch.setattr(win_login, "_test_copy", lambda p: p)
    monkeypatch.setattr(windows_client, "_client_binary", lambda p: p / "Wow.exe")
    api = Mock()
    api.find_window.return_value = 42
    monkeypatch.setattr(windows_client, "WindowsAPI", lambda: api)
    def forbid(*args, **kwargs):
        pytest.fail("Live WoW must not be overwritten or restarted")
    monkeypatch.setattr(agent_prepare, "deploy", forbid)
    result = agent_prepare.prepare_environment(config(tmp_path), start_client=True)
    assert result["status"] == "client_running"
    assert result["bridge_deployed"] is False


def test_session_import_and_preview_callable():
    from addon_forge.agent_session import run_session
    assert callable(run_session)


def test_session_preview_no_client_or_credentials(tmp_path):
    import json
    from addon_forge.agent_session import run_session
    path = tmp_path / "scenario.json"
    addon = tmp_path / "Demo"
    addon.mkdir()
    path.write_text(json.dumps({"version": 1, "addon": "Demo", "character": "Test", "peers": 0, "checks": [{"type": "player_in_world", "value": True}]}))
    assert run_session(config(tmp_path), path)["status"] == "plan_only"

def test_sdk_backend_skips_pixel_calibration(tmp_path, monkeypatch):
    from addon_forge import agent_session
    cfg = Config(wow_dir=tmp_path / "WoW", wine_prefix=tmp_path / "wine",
                 automation_backend="wowcontrol")
    assert cfg.automation_backend == "wowcontrol"

def test_sdk_pipe_rejects_unknown_process():
    from addon_forge.wowcontrol_pipe import verify_server_pid
    with pytest.raises(RuntimeError, match="process ID"):
        verify_server_pid(0, 0)

def test_sdk_request_rejects_unlisted_methods():
    from addon_forge.wowcontrol import request
    with pytest.raises(ValueError, match="Unapproved"):
        request("client.quit", expected_pid=123)
