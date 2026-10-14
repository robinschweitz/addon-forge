"""SDK-only observation cannot claim addon acceptance."""
from pathlib import Path
from unittest.mock import Mock

import pytest

from addon_forge.config import Config
from addon_forge import sdk_observer


def test_sdk_observer_uses_pid_bound_unit_and_no_lua(monkeypatch, tmp_path):
    from addon_forge import windows_client, win_login
    cfg = Config(wow_dir=tmp_path, wine_prefix=tmp_path / "wine",
                 automation_backend="wowcontrol")
    monkeypatch.setattr(sdk_observer, "_test_copy", lambda path: path)
    monkeypatch.setattr(windows_client, "_client_binary", lambda path: path / "Wow.exe")
    api = Mock()
    api.find_window.return_value = 7
    api.window_pid.return_value = 11620
    monkeypatch.setattr(sdk_observer, "WindowsAPI", lambda: api)
    calls = []
    def rpc(method, params=None, *, expected_pid):
        calls.append((method, params, expected_pid))
        if method == "client.getScreen":
            return {"screen": "world", "inWorld": True}
        assert method == "unit.get"
        return {"exists": True, "name": "Test"}
    plan = {"observer": "sdk", "character": "Test", "peers": 0,
            "checks": [{"type": "player_in_world", "value": True}]}
    result = sdk_observer.run_sdk_observations(cfg, plan, rpc=rpc)
    assert result["status"] == "observed"
    assert result["addon_verified"] is False
    assert result["pid"] == 11620
    assert [c[0] for c in calls] == [
        "client.getScreen", "unit.get", "client.getScreen", "unit.get"]
    assert all(pid == 11620 for _, _, pid in calls)


def test_sdk_observer_rejects_addon_checks_before_rpc():
    plan = {"observer": "sdk", "character": "Test", "peers": 0,
            "checks": [{"type": "frame_visible", "value": "ExampleFrame"}]}
    with pytest.raises(ValueError, match="cannot assess addon"):
        sdk_observer.run_sdk_observations(None, plan, rpc=lambda *a, **kw:
                                          pytest.fail("unexpected RPC"))
