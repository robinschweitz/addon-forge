"""Offline Windows login safeguards: never type credentials on unverified screens."""
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch
import json
import pytest

from addon_forge.config import Config
from addon_forge import win_login


def cfg(tmp_path):
    game = tmp_path / "test-wow"
    game.mkdir()
    (game / "Wow.exe").touch()
    (game / win_login.TEST_MARKER).write_text("{}")
    return Config(wow_dir=game, wine_prefix=tmp_path / "wine")


def test_refuses_unmarked_wow(tmp_path):
    game = tmp_path / "unmarked"
    game.mkdir()
    (game / "Wow.exe").touch()
    with pytest.raises(RuntimeError, match="marked"):
        win_login._test_copy(game)


def test_password_saved_only_to_vault(tmp_path, monkeypatch, capsys):
    config = cfg(tmp_path)
    vault = Mock()
    monkeypatch.setattr(win_login, "_vault", lambda: vault)
    win_login.save_credentials(config.wow_dir, "FORGETEST", read_password=lambda _: "SuperSecret12")
    assert vault.set_password.call_count == 2
    assert vault.set_password.call_args.args[-1] == "SuperSecret12"
    assert "SuperSecret12" not in capsys.readouterr().out
    assert not (config.wow_dir / win_login.CALIBRATION).exists()


def test_login_requires_calibration_before_launch(tmp_path, monkeypatch):
    config = cfg(tmp_path)
    launch = Mock()
    with pytest.raises(RuntimeError, match="calibration"):
        win_login.start_and_login(config, api=Mock(), launcher=launch)
    launch.assert_not_called()


def test_refuse_running_existing_window(tmp_path, monkeypatch):
    config = cfg(tmp_path)
    (config.wow_dir / win_login.CALIBRATION).write_text(
        json.dumps({"version": 1, "dimensions": [600, 600],
                    "fields": {"account": [100, 100], "password": [100, 140]},
                    "markers": [{"point": [40, 40], "rgb": "x"}] * 2}))
    monkeypatch.setattr(win_login, "_credentials", lambda wow: ("FORGETEST", "SECRET"))
    api = Mock()
    api.find_window.return_value = 1234
    launch = Mock()
    with pytest.raises(RuntimeError, match="already running"):
        win_login.start_and_login(config, api=api, launcher=launch)
    launch.assert_not_called()


def test_wrong_screen_never_types_password(tmp_path, monkeypatch):
    config = cfg(tmp_path)
    template = {"version": 1, "dimensions": [600, 600],
                "fields": {"account": [100, 100], "password": [100, 140]},
                "markers": [{"point": [40, 40], "rgb": "x"}] * 2}
    (config.wow_dir / win_login.CALIBRATION).write_text(json.dumps(template))
    monkeypatch.setattr(win_login, "_credentials", lambda wow: ("FORGETEST", "SECRET"))
    api = Mock()
    api.find_window.side_effect = [RuntimeError("found 0."), 45]
    api.window_pid.return_value = 77
    monkeypatch.setattr(win_login, "_matches", lambda *args: False)
    monkeypatch.setattr(win_login.time, "sleep", lambda _: None)
    clock = iter([0, 0.1, 99])
    monkeypatch.setattr(win_login.time, "monotonic", lambda: next(clock))
    launch = Mock(return_value=SimpleNamespace(pid=77))
    with pytest.raises(RuntimeError, match="Could not verify"):
        win_login.start_and_login(config, api=api, launcher=launch)
    api.type_text.assert_not_called()
    api.click.assert_not_called()
