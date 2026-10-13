"""Static safety checks, not a substitute for evaluating the NixOS VM."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def test_vm_exposed():
    text = (ROOT / "flake.nix").read_text()
    assert "nixosConfigurations.forge-vm" in text
    assert "./nix/hosts/forge-vm.nix" in text

def test_realm_ports_and_secrets():
    text = (ROOT / "nix/modules/workstation.nix").read_text()
    assert '"127.0.0.1:3724:3724"' in text
    assert '"127.0.0.1:8085:8085"' in text
    assert "openssl rand -hex 32" in text
    assert "docker-compose ${composeArgs} up -d" in text
    assert "down -v" not in text
