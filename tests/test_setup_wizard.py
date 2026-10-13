"""Setup bootstrap tests; no Nix/KVM or WoW installation required."""
import importlib.util
from pathlib import Path
import subprocess
import sys

MODULE = Path(__file__).resolve().parents[1] / "scripts/setup_wizard.py"
spec = importlib.util.spec_from_file_location("setup_wizard", MODULE)
setup = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = setup
spec.loader.exec_module(setup)

def test_client_validation(tmp_path):
    (tmp_path / "Wow.exe").write_bytes(b"MZ")
    assert setup.validate_client_dir(tmp_path) == tmp_path

def test_invalid_client(tmp_path):
    import pytest
    with pytest.raises(ValueError, match="No Wow.exe"):
        setup.validate_client_dir(tmp_path)

def test_runner_lookup(tmp_path):
    (tmp_path / "bin").mkdir()
    (tmp_path / "bin/run-forge-vm-vm").write_text("#!/bin/sh\n")
    assert setup.find_vm_runner(tmp_path).name == "run-forge-vm-vm"

def test_missing_runner(tmp_path):
    import pytest
    with pytest.raises(RuntimeError):
        setup.find_vm_runner(tmp_path)

def test_nix_uses_arg_array_not_shell(monkeypatch):
    observed = []
    def stub(args, **kw):
        observed.append((args, kw))
        return subprocess.CompletedProcess(args, 0, "/nix/store/a-vm\n")
    monkeypatch.setattr(setup.subprocess, "run", stub)
    assert setup.build_vm("/nix/store/source") == Path("/nix/store/a-vm")
    assert observed[0][0][-1].endswith("#nixosConfigurations.forge-vm.config.system.build.vm")
    assert observed[0][1]["check"] is True

def test_guest_share_read_only(monkeypatch, tmp_path):
    observed = []
    def stub(args, **kw):
        observed.append((args, kw))
        return subprocess.CompletedProcess(args, 0)
    monkeypatch.setattr(setup.subprocess, "run", stub)
    runner = tmp_path / "run-forge-vm-vm"
    assert setup.launch_vm(runner, tmp_path, tmp_path / "client") == 0
    opts = observed[0][1]["env"]["QEMU_OPTS"]
    assert "mount_tag=forgeclient" in opts
    assert "readonly=on" in opts
    assert observed[0][1]["cwd"] == tmp_path

def test_check_only_does_not_write(monkeypatch, tmp_path):
    monkeypatch.setattr(setup, "check_host", lambda *a, **kw: [("PASS", "Host", "ok")])
    state = tmp_path / "state"
    assert setup.main(["--check-only", "--state-dir", str(state)]) == 0
    assert not state.exists()

def test_dry_run_does_not_build(monkeypatch, tmp_path):
    monkeypatch.setattr(setup, "check_host", lambda *a, **kw: [("PASS", "Host", "ok")])
    monkeypatch.setattr(setup, "build_vm", lambda *_: (_ for _ in ()).throw(AssertionError("called")))
    assert setup.main(["--dry-run", "--state-dir", str(tmp_path / "state")]) == 0

def test_host_failure_blocks_setup(monkeypatch, tmp_path):
    monkeypatch.setattr(setup, "check_host", lambda *a, **kw: [("FAIL", "Nix", "missing")])
    assert setup.main(["--yes", "--state-dir", str(tmp_path / "state")]) == 2

def test_build_only_without_host_gui(monkeypatch, tmp_path):
    monkeypatch.setattr(setup, "check_host", lambda *a, **kw: [("PASS", "Host", "ok")])
    (tmp_path / "bin").mkdir()
    (tmp_path / "bin/run-forge-vm-vm").write_text("runner")
    monkeypatch.setattr(setup, "build_vm", lambda *_: tmp_path)
    assert setup.main(["--build-only", "--state-dir", str(tmp_path / "state")]) == 0

def test_guest_system_packages_declared_once():
    """Prevent duplicate Nix definitions from breaking flake evaluation."""
    host = Path(__file__).resolve().parents[1] / "nix/hosts/forge-vm.nix"
    content = host.read_text()
    assert content.count("environment.systemPackages =") == 1
    assert "forge-import-client" in content
    assert "xfce.thunar" in content

def test_explicit_torrent_opt_in_marks_guest_config(monkeypatch, tmp_path):
    from pathlib import Path
    import subprocess

    monkeypatch.setattr(setup, "check_host", lambda *a, **kw: [("PASS", "Host", "ok")])
    runner_root = tmp_path / "nix-runner"
    (runner_root / "bin").mkdir(parents=True)
    (runner_root / "bin/run-forge-vm-vm").write_text("#!/bin/sh")
    monkeypatch.setattr(setup, "build_vm", lambda *_: runner_root)
    passed = []

    def fake_launch(runner, workdir, share, *, guest_config=None):
        passed.append(guest_config)
        assert (guest_config / "download-source").read_text() == "rising-gods\n"
        return 0

    monkeypatch.setattr(setup, "launch_vm", fake_launch)
    assert setup.main(["--yes", "--client-source", "rising-gods",
                       "--state-dir", str(tmp_path / "state")]) == 0
    assert passed


def test_no_opt_in_removes_stale_download_marker(monkeypatch, tmp_path):
    monkeypatch.setattr(setup, "check_host", lambda *a, **kw: [("PASS", "Host", "ok")])
    root = tmp_path / "runner"
    (root / "bin").mkdir(parents=True)
    (root / "bin/run-forge-vm-vm").write_text("#!/bin/sh")
    monkeypatch.setattr(setup, "build_vm", lambda *_: root)
    state = tmp_path / "state"
    marker = state / "guest-config/download-source"
    marker.parent.mkdir(parents=True)
    marker.write_text("rising-gods\n")
    def check_launch(runner, workdir, share, *, guest_config=None):
        assert not (guest_config / "download-source").exists()
        return 0
    monkeypatch.setattr(setup, "launch_vm", check_launch)
    assert setup.main(["--yes", "--state-dir", str(state)]) == 0


def test_client_and_source_mutually_exclusive(tmp_path):
    import pytest
    with pytest.raises(SystemExit) as error:
        setup.parser().parse_args(["--client", str(tmp_path), "--client-source", "rising-gods"])
    assert error.value.code == 2
