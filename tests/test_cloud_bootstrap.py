"""Offline smoke tests for opt-in Hetzner bootstrap."""
import importlib.util
from pathlib import Path
import pytest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("forge_cloud", ROOT/"scripts/cloud/hetzner.py")
cloud = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cloud)

def config(tmp_path, source="1.1.1.1/32"):
    file = tmp_path/"cloud.toml"
    file.write_text('[server]\nname="addon-forge-realm"\ntype="cx43"\nlocation="fsn1"\nimage="ubuntu-24.04"\nssh_key="developer"\n[network]\nssh_source="'+source+'"\n')
    return file

def test_plan_never_calls_hcloud(monkeypatch,tmp_path):
    monkeypatch.setattr(cloud,"execute",lambda *args, **kw: (_ for _ in ()).throw(AssertionError("unexpected API call")))
    assert cloud.main(["plan","--config",str(config(tmp_path))]) == 0

@pytest.mark.parametrize("source",["0.0.0.0/0","1.1.1.0/24","10.0.0.1/32","203.0.113.10/32"])
def test_rejects_unsafe_firewalls(source,tmp_path):
    with pytest.raises(ValueError):
        cloud.configuration(config(tmp_path,source))

def test_cloud_profile_is_headless():
    host=(ROOT/"nix/hosts/forge-cloud.nix").read_text()
    assert "client.enable = false;" in host
    assert "realm.enable = true;" in host
    assert "PasswordAuthentication = false;" in host
    flake=(ROOT/"flake.nix").read_text()
    assert "nixosModules.cloudRealm" in flake

def test_ssh_key_name_with_at_sign(tmp_path):
    file = config(tmp_path)
    file.write_text(file.read_text().replace('ssh_key="developer"', 'ssh_key="robin@DESKTOP-KRLA5G1"'))
    server, source = cloud.configuration(file)
    assert server["ssh_key"] == "robin@DESKTOP-KRLA5G1"
    assert source == "1.1.1.1/32"

def test_active_hcloud_context_accepted_without_env(monkeypatch, tmp_path):
    monkeypatch.delenv("HCLOUD_TOKEN", raising=False)
    monkeypatch.delenv("HCLOUD_CONTEXT", raising=False)
    monkeypatch.setattr(cloud.shutil, "which", lambda name: "/usr/bin/hcloud")
    seen = []
    def fake_execute(argv, input_text=None):
        seen.append(argv)
        if argv[:2] == ["ssh-key", "describe"]:
            return '{"name": "robin@DESKTOP-KRLA5G1"}'
        return '[]'
    monkeypatch.setattr(cloud, "execute", fake_execute)
    assert cloud.main(["check", "--config", str(config(tmp_path))]) == 0
    assert ["ssh-key", "describe", "developer", "-o", "json"] in seen
