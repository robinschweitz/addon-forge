"""Test-copy marker and vault safeguards for the SDK login."""
from unittest.mock import Mock
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
    assert sorted(p.name for p in config.wow_dir.iterdir()) == sorted(["Wow.exe", win_login.TEST_MARKER])


def test_missing_vault_entry_fails_closed(tmp_path, monkeypatch):
    vault = Mock()
    vault.get_password.return_value = None
    monkeypatch.setattr(win_login, "_vault", lambda: vault)
    with pytest.raises(RuntimeError, match="No stored local test account"):
        win_login._credentials(cfg(tmp_path).wow_dir)


def test_member_slot_has_its_own_vault_entry(tmp_path, monkeypatch):
    config = cfg(tmp_path)
    vault = Mock()
    monkeypatch.setattr(win_login, "_vault", lambda: vault)
    win_login.save_credentials(config.wow_dir, "FORGEMEMBER", read_password=lambda _: "Member12345", slot="member")
    main = win_login._vault_service(config.wow_dir)
    member = win_login._vault_service(config.wow_dir, "member")
    assert member == main + "-member"
    assert {c.args[0] for c in vault.set_password.call_args_list} == {member}
    with pytest.raises(ValueError):
        win_login._vault_service(config.wow_dir, "other")
