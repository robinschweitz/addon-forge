"""Safety-first tests of local AzerothCore bootstrap (no daemon/game needed)."""
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from addon_forge import local_realm as realm


def fixture_paths(tmp_path):
    original = tmp_path / "RisingGods"
    original.mkdir()
    (original / "Wow.exe").write_bytes(b"game")
    (original / "Data" / "deDE").mkdir(parents=True)
    (original / "Data" / "deDE" / "realmlist.wtf").write_text(
        "set realmlist rising-gods.example\n", encoding="utf-8"
    )
    (original / "WTF").mkdir()
    (original / "WTF" / "credentials.wtf").write_text("private")
    return original, tmp_path / "ForgeTest", tmp_path / "azerothcore"


def test_plan_does_not_touch_local_files_or_docker(tmp_path, monkeypatch):
    source, target, checkout = fixture_paths(tmp_path)
    monkeypatch.setattr(realm, "check_tools", lambda: pytest.fail("unexpected Docker"))
    realm.setup(source, target, checkout, "deDE", tmp_path / "forge.local.toml")
    assert not target.exists() and not checkout.exists()
    assert "rising-gods.example" in (source / "Data" / "deDE" / "realmlist.wtf").read_text()


def test_copies_isolated_client_without_rising_gods_wtf(tmp_path):
    source, target, _ = fixture_paths(tmp_path)
    realm.make_test_copy(source, target)
    assert (target / "Wow.exe").exists()
    assert not (target / "WTF").exists()
    assert json.loads((target / realm.MARKER).read_text())["source"] == str(source)
    # Never modify the original game.
    assert (source / "WTF" / "credentials.wtf").read_text() == "private"


def test_existing_nonforge_folder_not_overwritten(tmp_path):
    source, target, _ = fixture_paths(tmp_path)
    target.mkdir()
    (target / "anything").write_text("untouched")
    with pytest.raises(RuntimeError, match="unmarked"):
        realm.make_test_copy(source, target)
    assert (target / "anything").read_text() == "untouched"


def test_overlapping_paths_rejected(tmp_path):
    source, _, realm_path = fixture_paths(tmp_path)
    with pytest.raises(ValueError, match="separate"):
        realm.paths(source, source / "test", realm_path)


def test_local_env_private_and_loopback_only(tmp_path):
    root = tmp_path / "ac"
    root.mkdir()
    realm.ensure_local_env(root)
    contents = (root / ".env").read_text()
    assert "DOCKER_DB_ROOT_PASSWORD=" in contents
    for name, port in realm.LOCAL_PORTS.items():
        assert f"{name}=127.0.0.1:{port}" in contents
    realm.ensure_local_env(root)
    assert (root / ".env").read_text() == contents


def test_existing_insecure_env_rejected_not_overwritten(tmp_path):
    root = tmp_path / "ac"
    root.mkdir()
    env = root / ".env"
    env.write_text("DOCKER_DB_ROOT_PASSWORD=abc\nDOCKER_WORLD_EXTERNAL_PORT=0.0.0.0:8085\n")
    with pytest.raises(RuntimeError):
        realm.ensure_local_env(root)
    assert "0.0.0.0" in env.read_text()


def test_compose_rejects_exposed_public_bindings(tmp_path, monkeypatch):
    root = tmp_path / "ac"
    root.mkdir()
    realm.ensure_local_env(root)
    services = {}
    for name, port in realm.EXPECTED_PORTS:
        services.setdefault(name, {"ports": []})["ports"].append({
            "target": port, "published": str(port), "host_ip": "127.0.0.1"
        })
    services["ac-database"]["environment"] = {
        "MYSQL_ROOT_PASSWORD": (root / ".env").read_text().split("DOCKER_DB_ROOT_PASSWORD=")[1].splitlines()[0]
    }
    monkeypatch.setattr(realm, "_run", lambda *a, **kw:
                        SimpleNamespace(stdout=json.dumps({"services": services})))
    realm.check_compose(root)
    services["ac-worldserver"]["ports"][0]["host_ip"] = "0.0.0.0"
    with pytest.raises(RuntimeError, match="Unsafe Docker host binding"):
        realm.check_compose(root)


def test_config_file_refuses_existing_other_client(tmp_path):
    _, target, checkout = fixture_paths(tmp_path)
    path = tmp_path / "forge.local.toml"
    path.write_text('[client]\nwow_dir="C:/SomeoneElse"\n[realm]\nsource_dir="C:/wrong"\n')
    with pytest.raises(RuntimeError, match="won't overwrite"):
        realm.local_config_file(path, target, checkout)
    assert "SomeoneElse" in path.read_text()


def test_symlinks_refused_before_copy(tmp_path):
    source, target, _ = fixture_paths(tmp_path)
    outside = tmp_path / "other"
    outside.mkdir()
    try:
        (source / "linked").symlink_to(outside, target_is_directory=True)
    except OSError:
        pytest.skip("symlinks unavailable")
    with pytest.raises(ValueError, match="link"):
        realm.make_test_copy(source, target)
    assert not target.exists()

def test_adopt_existing_copy_preserves_original_and_moves_only_test_wtf(tmp_path):
    source, target, _ = fixture_paths(tmp_path)
    target.mkdir()
    (target / "Wow.exe").write_bytes(b"copied-game")
    (target / "WTF").mkdir()
    (target / "WTF" / "Config.wtf").write_text("Rising Gods configuration")
    realm.adopt_existing_test_copy(source, target)
    assert (target / realm.MARKER).is_file()
    assert not (target / "WTF").exists()
    assert (target / ".forge-original-WTF-backup" / "Config.wtf").read_text() == "Rising Gods configuration"
    assert (source / "WTF" / "credentials.wtf").read_text() == "private"
    realm.adopt_existing_test_copy(source, target)


def test_adoption_refuses_wtf_backup_collision(tmp_path):
    source, target, _ = fixture_paths(tmp_path)
    target.mkdir()
    (target / "Wow.exe").touch()
    (target / "WTF").mkdir()
    (target / ".forge-original-WTF-backup").mkdir()
    with pytest.raises(RuntimeError, match="both WTF"):
        realm.adopt_existing_test_copy(source, target)
    assert not (target / realm.MARKER).exists()


def test_existing_copy_requires_explicit_adoption(tmp_path, monkeypatch):
    source, target, checkout = fixture_paths(tmp_path)
    target.mkdir()
    (target / "Wow.exe").touch()
    monkeypatch.setattr(realm, "check_tools", lambda: None)
    with pytest.raises(RuntimeError, match="--adopt-existing-test-wow"):
        realm.setup(source, target, checkout, "deDE",
                    tmp_path / "forge.local.toml", approve=True)
    assert not checkout.exists()
