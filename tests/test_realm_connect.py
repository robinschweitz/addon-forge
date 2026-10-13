"""Offline SSH tunnel and local realmlist safety tests."""
from pathlib import Path
from unittest.mock import patch
import pytest
from addon_forge.realm_connect import configure_realmlist, ssh_tunnel_command


def test_tunnel_forwards_two_private_ports():
    args = ssh_tunnel_command("2.29.101.138")
    for port in (3724, 8085):
        assert f"127.0.0.1:{port}:127.0.0.1:{port}" in args
    assert args[-1] == "root@2.29.101.138"
    assert "StrictHostKeyChecking=yes" in args


@pytest.mark.parametrize("bad", ["-F evil", "bad host", "127.0.0.1;cmd", "", "../bad"])
def test_rejects_unsafe_host(bad):
    with pytest.raises(ValueError):
        ssh_tunnel_command(bad)


def test_realmlist_backup_and_idempotence(tmp_path):
    root = tmp_path / "WoW"
    (root / "Data" / "enUS").mkdir(parents=True)
    (root / "Wow.exe").write_bytes(b"game")
    target = root / "Data" / "enUS" / "realmlist.wtf"
    original = b"set realmlist localhost\r\nset patchlist localhost\r\n"
    target.write_bytes(original)
    result, backup = configure_realmlist(root, locale="enUS")
    assert result == target
    assert backup.read_bytes() == original
    assert "set realmlist 127.0.0.1" in target.read_text()
    result2, backup2 = configure_realmlist(root, locale="enUS")
    assert result2 == target and backup2 == backup


def test_realmlist_never_overwrites_existing_backup(tmp_path):
    root = tmp_path / "WoW"
    (root / "Data" / "enUS").mkdir(parents=True)
    (root / "Wow.exe").touch()
    target = root / "Data" / "enUS" / "realmlist.wtf"
    target.write_text("set realmlist other.example")
    backup = target.with_name("realmlist.wtf.forge-backup")
    backup.write_text("untouched")
    with pytest.raises(RuntimeError):
        configure_realmlist(root, locale="enUS")
    assert backup.read_text() == "untouched"
    assert target.read_text() == "set realmlist other.example"
