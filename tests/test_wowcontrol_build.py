"""The external SDK build is pinned, opt-in and never touches test WoW."""
import json
import struct
import tomllib
from pathlib import Path

import pytest

from addon_forge import wowcontrol_build as sdk
from addon_forge.cli import make_parser


def pe(path: Path, machine: int):
    data = bytearray(70)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 60, 64)
    data[64:68] = b"PE" + bytes((0, 0))
    struct.pack_into("<H", data, 68, machine)
    path.write_bytes(data)


def test_signed_architecture_is_checked(tmp_path):
    binary = tmp_path / "WowInjector.exe"
    pe(binary, 0x14C)
    assert sdk._pe_machine(binary) == 0x14C
    pe(binary, 0x8664)
    assert sdk._pe_machine(binary) == 0x8664
    binary.write_bytes(b"NotPE")
    with pytest.raises(RuntimeError, match="PE"):
        sdk._pe_machine(binary)


def test_local_config_preserves_other_tables_and_backup(tmp_path):
    cfg = tmp_path / "forge.local.toml"
    original = ("# local settings\n[client]\nwow_dir = 'F:/test-wow'\n"
                "window_name = 'World of Warcraft'\n\n[realm]\nsource_dir = 'E:/realm'\n")
    cfg.write_text(original)
    out = {"wowcontrol_injector": "C:/sdk/bin/release/WowInjector.exe",
           "wowcontrol_dll": "C:/sdk/bin/release/WoWControlSDK.dll"}
    backup = tmp_path / ".forge-tools"
    assert sdk._write_local_config(cfg, out, "Test Realm", backup_dir=backup)
    updated = cfg.read_text()
    parsed = tomllib.loads(updated)
    assert parsed["realm"]["source_dir"] == "E:/realm"
    assert parsed["client"]["automation_backend"] == "wowcontrol"
    assert parsed["client"]["wowcontrol_realm"] == "Test Realm"
    assert parsed["client"]["wowcontrol_dll"] == out["wowcontrol_dll"]
    assert (backup / "forge-local-toml.before-wowcontrol").read_text() == original
    assert sdk._write_local_config(cfg, out, "Test Realm", backup_dir=backup)
    assert cfg.read_text() == updated


def test_without_realm_build_paths_do_not_auto_enable_backend(tmp_path):
    cfg = tmp_path / "forge.local.toml"
    cfg.write_text("[client]\nwow_dir = 'F:/test-wow'\n")
    paths = {"wowcontrol_dll": "C:/sdk/WoWControlSDK.dll",
             "wowcontrol_injector": "C:/sdk/WowInjector.exe"}
    assert not sdk._write_local_config(cfg, paths, None, backup_dir=tmp_path / "private")
    parsed = tomllib.loads(cfg.read_text())
    assert "automation_backend" not in parsed["client"]
    assert parsed["client"]["wowcontrol_dll"] == paths["wowcontrol_dll"]


def test_bad_realm_does_not_overwrite_config(tmp_path):
    cfg = tmp_path / "forge.local.toml"
    cfg.write_text("[client]\nwow_dir = 'F:/test-wow'\n")
    with pytest.raises(ValueError, match="Realm name"):
        sdk._write_local_config(cfg, {}, "A\n[realm]", backup_dir=tmp_path)
    assert cfg.read_text() == "[client]\nwow_dir = 'F:/test-wow'\n"


def test_preview_is_dry_run_without_configuration(tmp_path, monkeypatch):
    def no_call(*args, **kwargs):
        pytest.fail("Preview should not run Git, compiler or Windows checks")
    monkeypatch.setattr(sdk, "_invoke", no_call)
    monkeypatch.setattr(sdk, "_prerequisites", no_call)
    out = sdk.setup(tmp_path / "missing.toml")
    assert out["status"] == "plan_only"
    assert out["revision"] == sdk.PINNED_SHA
    assert not (tmp_path / ".forge-tools").exists()


def test_missing_tools_does_not_download_or_build(tmp_path, monkeypatch):
    from addon_forge import win_login
    monkeypatch.setattr(sdk.sys, "platform", "win32")
    monkeypatch.setattr(win_login, "_test_copy", lambda p: p)
    monkeypatch.setattr(sdk, "_prerequisites", lambda: {
        "git": None, "cmake": None, "visual_studio_cpp": None})
    def no_call(*args, **kwargs):
        pytest.fail("No Git/CMake should run when prerequisites are missing")
    monkeypatch.setattr(sdk, "_invoke", no_call)
    config = tmp_path / "forge.local.toml"
    config.write_text("[client]\nwow_dir = 'F:/test-wow'\n")
    assert sdk.setup(config, approve=True)["status"] == "missing_build_tools"
    assert not (tmp_path / ".forge-tools").exists()


def test_parser_exposes_guarded_setup():
    opts = make_parser().parse_args(["agent", "wowcontrol-setup"])
    assert opts.approve_build is False
    opts = make_parser().parse_args(
        ["agent", "wowcontrol-setup", "--approve-build", "--realm-name", "Test Realm"])
    assert opts.approve_build and opts.realm_name == "Test Realm"
    assert not opts.install_prereqs
    opts = make_parser().parse_args(["agent", "wowcontrol-setup", "--approve-build", "--install-prereqs"])
    assert opts.install_prereqs


def test_opt_in_winget_only_for_missing_packages(monkeypatch):
    invoked = []
    monkeypatch.setattr(sdk.shutil, "which", lambda name: "C:/winget.exe" if name == "winget" else None)
    monkeypatch.setattr(sdk, "_invoke", lambda argv, **kwargs: invoked.append(argv) or "")
    sdk._install_prerequisites({"git": "C:/git.exe", "cmake": None,
                                "visual_studio_cpp": None})
    assert len(invoked) == 2
    assert "Kitware.CMake" in invoked[0]
    assert "Microsoft.VisualStudio.2022.BuildTools" in invoked[1]
    assert "--override" in invoked[1]
    assert all("--accept-package-agreements" in argv for argv in invoked)
    assert all("--accept-source-agreements" in argv for argv in invoked)
    assert all(argv[0] == "C:/winget.exe" for argv in invoked)


def test_approved_build_rejects_external_workspaces(tmp_path, monkeypatch):
    monkeypatch.setattr(sdk.sys, "platform", "win32")
    config = tmp_path / "forge.local.toml"
    config.write_text("[client]\nwow_dir = 'F:/test-wow'\n")
    with pytest.raises(RuntimeError, match="ignored .forge-tools"):
        sdk.setup(config, approve=True, workspace=tmp_path / "outside")


def test_approved_build_refuses_linked_configuration(tmp_path, monkeypatch):
    monkeypatch.setattr(sdk.sys, "platform", "win32")
    original = tmp_path / "some-other-config.toml"
    original.write_text("[client]\nwow_dir = 'F:/test-wow'\n")
    alias = tmp_path / "forge.local.toml"
    try:
        alias.symlink_to(original)
    except (OSError, NotImplementedError):
        pytest.skip("Symlinks unavailable")
    with pytest.raises(RuntimeError, match="linked local configuration"):
        sdk.setup(alias, approve=True)
    assert original.read_text() == "[client]\nwow_dir = 'F:/test-wow'\n"
