"""Read-only tests for guarded Hetzner NixOS installation."""
import importlib.util
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("forge_installer", ROOT / "scripts/cloud/install_nixos.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

def test_install_disallows_missing_confirmations(monkeypatch, tmp_path, capsys):
    key = tmp_path / "id_ed25519.pub"
    key.write_text("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICLexample developer@host\n")
    monkeypatch.setattr(installer, "supported_install_platform", lambda: True)
    monkeypatch.setattr(installer.shutil, "which", lambda x: "/bin/" + x)
    monkeypatch.setattr(installer, "get_server", lambda n: {
        "id": 170096651, "status": "running",
        "public_net": {"ipv4": {"ip": "192.0.2.55"}}
    })
    monkeypatch.setattr(installer, "verify_boot_disk", lambda host: ["sda"])
    def never_run(*args, **kwargs):
        raise AssertionError("No installation should run without confirmations")
    monkeypatch.setattr(installer, "cmd", never_run)
    result = installer.main(["install", "--public-key", str(key)])
    assert result == 2
    assert "--confirm-server-id 170096651" in capsys.readouterr().err

def test_read_only_preflight(monkeypatch, tmp_path):
    key = tmp_path / "id_ed25519.pub"
    key.write_text("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICLexample developer@host\n")
    monkeypatch.setattr(installer, "supported_install_platform", lambda: True)
    monkeypatch.setattr(installer.shutil, "which", lambda x: "/bin/" + x)
    monkeypatch.setattr(installer, "get_server", lambda n: {
        "id": 170096651, "status": "running",
        "public_net": {"ipv4": {"ip": "192.0.2.55"}}
    })
    monkeypatch.setattr(installer, "verify_boot_disk", lambda host: ["sda"])
    monkeypatch.setattr(installer, "cmd",
                        lambda *a, **kw: (_ for _ in ()).throw(AssertionError("no subprocess")))
    assert installer.main(["check", "--public-key", str(key)]) == 0

def test_rejects_multiple_disks(monkeypatch):
    monkeypatch.setattr(installer, "cmd", lambda a, **kwargs:
        SimpleNamespace(stdout="sda disk\nsdb disk\n"))
    try:
        installer.verify_boot_disk("192.0.2.10")
        assert False, "Expected safety exception"
    except RuntimeError as exc:
        assert "precisely one disk" in str(exc)
