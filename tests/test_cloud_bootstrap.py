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
        if argv[:2] == ["server-type", "describe"]:
            return '{"locations":[{"location":{"name":"fsn1"},"available":true}]}'
        if argv[:2] == ["ssh-key", "describe"]:
            return '{"name": "robin@DESKTOP-KRLA5G1"}'
        return '[]'
    monkeypatch.setattr(cloud, "execute", fake_execute)
    assert cloud.main(["check", "--config", str(config(tmp_path))]) == 0
    assert ["ssh-key", "describe", "developer", "-o", "json"] in seen

def test_existing_matching_firewall_is_reused(monkeypatch, tmp_path):
    monkeypatch.setattr(cloud.shutil, "which", lambda name: "hcloud")
    commands = []
    def fake_execute(argv, input_text=None):
        commands.append(argv)
        if argv[:2] == ["server-type", "describe"]:
            return '{"locations":[{"location":{"name":"fsn1"},"available":true}]}'
        if argv[:2] == ["ssh-key", "describe"]:
            return '{}'
        if argv[:2] == ["server", "list"]:
            return "[]"
        if argv[:2] == ["firewall", "list"]:
            return '[{"name":"addon-forge-realm-ssh"}]'
        if argv[:2] == ["firewall", "describe"]:
            return '{"name":"addon-forge-realm-ssh","rules":[{"direction":"in","protocol":"tcp","port":"22","source_ips":["1.1.1.1/32"]}],"applied_to":[]}'
        if argv[:2] == ["server", "create"]:
            return '{"id":12}'
        raise AssertionError(argv)
    monkeypatch.setattr(cloud, "execute", fake_execute)
    assert cloud.main(["apply", "--approve-cost", "--config", str(config(tmp_path))]) == 0
    assert not any(cmd[:2] == ["firewall","create"] for cmd in commands)

def test_unrelated_existing_firewall_is_not_reused(monkeypatch, tmp_path):
    monkeypatch.setattr(cloud.shutil, "which", lambda name: "hcloud")
    def fake_execute(argv, input_text=None):
        if argv[:2] == ["server-type", "describe"]:
            return '{"locations":[{"location":{"name":"fsn1"},"available":true}]}'
        if argv[:2] == ["ssh-key", "describe"]:
            return '{}'
        if argv[:2] == ["server", "list"]:
            return "[]"
        if argv[:2] == ["firewall", "list"]:
            return '[{"name":"addon-forge-realm-ssh"}]'
        if argv[:2] == ["firewall", "describe"]:
            return '{"rules":[{"direction":"in","protocol":"tcp","port":"22","source_ips":["0.0.0.0/0"]}],"applied_to":[]}'
        raise AssertionError(argv)
    monkeypatch.setattr(cloud, "execute", fake_execute)
    assert cloud.main(["apply", "--approve-cost", "--config", str(config(tmp_path))]) == 2

def test_failed_server_creation_explains_failure(monkeypatch, tmp_path, capsys):
    import subprocess
    monkeypatch.setattr(cloud.shutil, "which", lambda name: "hcloud")
    def fake_execute(argv, input_text=None):
        if argv[:2] == ["server-type", "describe"]:
            return '{"locations":[{"location":{"name":"fsn1"},"available":true}]}'
        if argv[:2] == ["ssh-key", "describe"]:
            return '{}'
        if argv[:2] in (["server", "list"], ["firewall", "list"]):
            return "[]"
        if argv[:2] == ["firewall", "create"]:
            return '{}'
        if argv[:2] == ["server", "create"]:
            raise subprocess.CalledProcessError(1, argv, stderr="resource_unavailable: chosen server type unavailable")
        raise AssertionError(argv)
    monkeypatch.setattr(cloud, "execute", fake_execute)
    assert cloud.main(["apply","--approve-cost","--config", str(config(tmp_path))]) == 2
    assert "resource_unavailable" in capsys.readouterr().err

def test_unavailable_server_type_blocks_creation(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(cloud.shutil, "which", lambda name: "hcloud")
    calls = []
    def fake_execute(argv, input_text=None):
        calls.append(argv)
        if argv[:2] == ["ssh-key", "describe"]:
            return '{}'
        if argv[:2] == ["server-type", "describe"]:
            return '{"name":"cx43","locations":[{"location":{"name":"fsn1"},"available":false}]}'
        raise AssertionError("No creation or resource listing should happen")
    monkeypatch.setattr(cloud, "execute", fake_execute)
    assert cloud.main(["check", "--config", str(config(tmp_path))]) == 2
    assert "unavailable" in capsys.readouterr().err
    assert not any(cmd[:2] == ["server", "create"] for cmd in calls)

def test_available_type_passes_existing_preflight(monkeypatch, tmp_path):
    monkeypatch.setattr(cloud.shutil, "which", lambda name: "hcloud")
    def fake_execute(argv, input_text=None):
        if argv[:2] == ["server-type", "describe"]:
            return '{"locations":[{"location":{"name":"fsn1"},"available":true}]}'
        if argv[:2] == ["ssh-key", "describe"]:
            return '{}'
        if argv[:2] == ["server-type", "describe"]:
            return '{"locations":[{"location":{"name":"fsn1"},"available":true}]}'
        if argv[:2] in (["server", "list"], ["firewall", "list"]):
            return "[]"
        raise AssertionError(argv)
    monkeypatch.setattr(cloud, "execute", fake_execute)
    assert cloud.main(["check", "--config", str(config(tmp_path))]) == 0
