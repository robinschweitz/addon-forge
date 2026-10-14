"""Fail-closed character selection: no input on incorrect screenshot/process."""
import json
from unittest.mock import Mock
import pytest

from addon_forge.config import Config
from addon_forge import win_character, agent_prepare


def cfg(tmp_path):
    wow = tmp_path / "WoW"
    wow.mkdir(exist_ok=True)
    return Config(wow_dir=wow, wine_prefix=tmp_path / "wine")


def test_invalid_character_never_selects(tmp_path):
    with pytest.raises(ValueError):
        win_character.read_character_calibration(tmp_path, "Test\n/run")


def test_missing_calibration_fail_closed(tmp_path, monkeypatch):
    cfg_ = cfg(tmp_path)
    monkeypatch.setattr(win_character, "_test_copy", lambda _: cfg_.wow_dir)
    api = Mock()
    with pytest.raises(RuntimeError, match="calibration"):
        win_character.enter_character(cfg_, "Test", pid=1234, api=api)
    api.tap.assert_not_called()


def test_wrong_process_never_press_enter(tmp_path, monkeypatch):
    cfg_ = cfg(tmp_path)
    monkeypatch.setattr(win_character, "_test_copy", lambda _: cfg_.wow_dir)
    monkeypatch.setattr(win_character, "read_character_calibration", lambda *_: {"markers": [], "dimensions": []})
    monkeypatch.setattr(win_character, "_matches_character", lambda *_: True)
    monkeypatch.setattr(win_character, "_client_binary", lambda _: cfg_.wow_dir / "Wow.exe")
    api = Mock()
    api.find_window.return_value = 42
    api.window_pid.return_value = 987
    with pytest.raises(RuntimeError, match="different process"):
        win_character.enter_character(cfg_, "Test", pid=1234, api=api)
    api.tap.assert_not_called()


def test_character_entry_requires_login_and_start(tmp_path):
    with pytest.raises(ValueError, match="requires"):
        agent_prepare.prepare_environment(cfg(tmp_path), enter_character="Test")
