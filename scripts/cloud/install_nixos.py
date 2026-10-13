#!/usr/bin/env python3
"""Explicitly approved NixOS installation onto a NEW, disposable Hetzner server.

Run under Linux/WSL2 with Nix, hcloud and SSH installed. Never runs on import.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

FLAKE = ".#forge-cloud"
BOOT_DISK = "/dev/sda"

def cmd(arguments, **kwargs):
    return subprocess.run(arguments, check=True, text=True, **kwargs)

def get_server(name):
    result = cmd(["hcloud", "server", "describe", name, "-o", "json"],
                 capture_output=True)
    obj = json.loads(result.stdout)
    return obj.get("server", obj)

def ssh_command(host, remote_command):
    return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
            "-o", "StrictHostKeyChecking=accept-new", "root@" + host, remote_command]

def verify_boot_disk(host):
    result = cmd(ssh_command(host, "lsblk -dn -o NAME,TYPE"),
                 capture_output=True)
    disks = [row.split()[0] for row in result.stdout.splitlines()
             if len(row.split()) == 2 and row.split()[1] == "disk"]
    if disks != ["sda"]:
        raise RuntimeError("Refusing to install: expected precisely one disk named "
                           "sda; found: " + ", ".join(disks))
    return disks

def supported_install_platform():
    return os.name == "posix"


def main(argv=None):
    parser = argparse.ArgumentParser(description="Install NixOS, wiping /dev/sda")
    parser.add_argument("action", choices=["check", "install"])
    parser.add_argument("--name", default="addon-forge-realm")
    parser.add_argument("--public-key", required=True,
                        help="Path to an OpenSSH .pub public key, not a private key")
    parser.add_argument("--confirm-server-id", type=int)
    parser.add_argument("--confirm-wipe-disk", choices=[BOOT_DISK])
    args = parser.parse_args(argv)
    try:
        if not supported_install_platform():
            raise RuntimeError("Run this command from Linux or WSL2 with Nix installed")
        for executable in ("hcloud", "ssh", "nix"):
            if shutil.which(executable) is None:
                raise RuntimeError(f"Missing {executable}; install it in Linux/WSL2")
        key_path = Path(args.public_key).expanduser().resolve(strict=True)
        pub = key_path.read_text().strip()
        if not pub.startswith(("ssh-ed25519 ", "ssh-rsa ", "ecdsa-sha2-")) or "\n" in pub:
            raise RuntimeError("Expected a single OpenSSH public key (.pub)")
        server = get_server(args.name)
        server_id = server.get("id")
        address = (server.get("public_net") or {}).get("ipv4") or {}
        ip = address.get("ip")
        if not isinstance(server_id, int) or not ip:
            raise RuntimeError("Hetzner server has no valid ID / public IPv4")
        if server.get("status") != "running":
            raise RuntimeError("Server must be running")
        print(f"Hetzner target: {args.name}, ID {server_id}, IPv4 {ip}")
        verify_boot_disk(ip)
        print(f"Verified boot disk: {BOOT_DISK}; disk contents will be LOST.")
        if args.action == "check":
            print("Read-only checks passed. No installation performed.")
            return 0
        if args.confirm_server_id != server_id or args.confirm_wipe_disk != BOOT_DISK:
            raise RuntimeError(
                f"Destructive install requires --confirm-server-id {server_id} "
                f"--confirm-wipe-disk {BOOT_DISK}"
            )
        # disko + NixOS rebuild cannot be performed natively from Windows.
        # Extra files are copied to installed system (not the public Nix store).
        with tempfile.TemporaryDirectory(prefix="forge-nixos-") as tmp:
            sshdir = Path(tmp) / "root" / ".ssh"
            sshdir.mkdir(parents=True, mode=0o700)
            (sshdir / "authorized_keys").write_text(pub + "\n")
            (sshdir / "authorized_keys").chmod(0o600)
            cmd(["nix", "run", "github:nix-community/nixos-anywhere", "--",
                 "--flake", FLAKE, "--target-host", "root@" + ip,
                 "--extra-files", tmp])
        print("Installer exited successfully; verify SSH login and realm service.")
        return 0
    except (OSError, KeyError, ValueError, RuntimeError, subprocess.CalledProcessError) as ex:
        detail = (ex.stderr or ex.stdout or "") if isinstance(ex, subprocess.CalledProcessError) else ""
        print(f"install: {ex} {detail}".strip(), file=sys.stderr)
        return 2

if __name__ == "__main__":
    raise SystemExit(main())
