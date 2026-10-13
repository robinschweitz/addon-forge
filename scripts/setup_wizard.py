#!/usr/bin/env python3
"""Host-side NixOS VM bootstrap: no host OS modifications or game downloads."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys

GIB = 1024**3
VM_ATTR = "nixosConfigurations.forge-vm.config.system.build.vm"

def default_state_dir() -> Path:
    base = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state")
    return base / "addon-forge" / "vm"

def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="forge-setup",
        description="Build and start an isolated NixOS WoW 3.3.5a addon-development VM.")
    p.add_argument("--flake", default=".", help="Source flake path/ref (supplied by the Nix app)")
    client = p.add_mutually_exclusive_group()
    client.add_argument("--client", type=Path,
                        help="Existing legitimately obtained WoW 3.3.5a client folder")
    client.add_argument("--client-source", choices=("rising-gods",),
                        help="Explicitly opt in to a third-party BitTorrent download inside the VM")
    p.add_argument("--state-dir", type=Path, default=default_state_dir(), help="Persistent VM disk location")
    p.add_argument("--check-only", action="store_true", help="Check host; do not build or start")
    p.add_argument("--build-only", action="store_true", help="Build the VM without starting")
    p.add_argument("--dry-run", action="store_true", help="Display actions without changes")
    p.add_argument("--yes", action="store_true", help="Skip interactive start confirmation")
    return p

def nearest_existing_parent(path: Path) -> Path:
    while not path.exists() and path != path.parent:
        path = path.parent
    return path

def validate_client_dir(directory: Path) -> Path:
    source = directory.expanduser().resolve()
    if not source.is_dir():
        raise ValueError(f"WoW client folder does not exist: {source}")
    if not any((source / filename).is_file() for filename in ("Wow.exe", "WoW.exe", "wow.exe")):
        raise ValueError(f"No Wow.exe found in {source} (pass game installation root)")
    return source

def check_host(state_dir: Path, starting: bool) -> list[tuple[str, str, str]]:
    results = []
    linux = sys.platform == "linux" and platform.machine() in ("x86_64", "amd64")
    results.append(("PASS" if linux else "FAIL", "Host", "x86_64 Linux required"))
    results.append(("PASS" if shutil.which("nix") else "FAIL", "Nix", "Nix CLI required"))
    kvm = os.access("/dev/kvm", os.R_OK | os.W_OK)
    results.append(("PASS" if kvm else ("FAIL" if starting else "WARN"),
                    "KVM", "Read/write access to /dev/kvm"))
    display = os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")
    results.append(("PASS" if display else ("FAIL" if starting else "WARN"),
                    "Display", "Host graphical session for QEMU"))
    available = shutil.disk_usage(nearest_existing_parent(state_dir)).free
    results.append(("PASS" if available >= 30 * GIB else "WARN",
                    "Storage", f"{available // GIB} GiB free; 30+ GiB recommended"))
    try:
        values = dict(line.split(":", 1) for line in Path("/proc/meminfo").read_text().splitlines() if ":" in line)
        available_kib = int(values["MemAvailable"].strip().split()[0])
        results.append(("PASS" if available_kib >= 14 * 1024**2 else "WARN",
                        "Memory", f"{available_kib // 1024**2} GiB available; VM requests 12 GiB"))
    except (OSError, ValueError, KeyError):
        results.append(("WARN", "Memory", "Unable to detect available memory"))
    return results

def find_vm_runner(output: Path) -> Path:
    candidates = sorted((output / "bin").glob("run-*-vm"))
    if len(candidates) != 1 or not candidates[0].is_file():
        raise RuntimeError(f"Expected one NixOS VM runner in {output / 'bin'}; found {len(candidates)}")
    return candidates[0]

def build_vm(flake: str) -> Path:
    cmd = ["nix", "--extra-experimental-features", "nix-command flakes", "build",
           "--no-link", "--print-out-paths", "--print-build-logs", f"{flake}#{VM_ATTR}"]
    print("\nBuilding the full NixOS desktop VM. Significant downloads may be required.", flush=True)
    result = subprocess.run(cmd, check=True, text=True, stdout=subprocess.PIPE)
    paths = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    if len(paths) != 1:
        raise RuntimeError(f"Unexpected Nix build output: {result.stdout!r}")
    return Path(paths[0])

def launch_vm(runner: Path, workdir: Path, share: Path,
              *, guest_config: Path | None = None) -> int:
    env = os.environ.copy()
    # NixOS vm runner forwards QEMU_OPTS to QEMU; use read-only 9p import.
    option = f"-virtfs local,path={share},mount_tag=forgeclient,security_model=none,readonly=on"
    if guest_config is not None:
        # The guest sees only this read-only marker; the download runs in the VM.
        option += f" -virtfs local,path={guest_config},mount_tag=forgeconfig,security_model=none,readonly=on"
    env["QEMU_OPTS"] = (env.get("QEMU_OPTS", "") + " " + option).strip()
    print(f"\nStarting NixOS VM in {workdir}", flush=True)
    print(f"Client import share: {share}", flush=True)
    if guest_config is not None and (guest_config / "download-source").exists():
        print("Rising Gods torrent download requested; guest systemd will start it automatically.", flush=True)
        print("In the VM: journalctl -u forge-client-fetch -f", flush=True)
    else:
        print("To import a local client in the guest run: sudo forge-import-client", flush=True)
    print("The configured test realm starts independently via systemd.", flush=True)
    print("Inside VM: forge-realm status ; forge-realm console", flush=True)
    return subprocess.run([str(runner)], cwd=workdir, env=env, check=False).returncode

def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    state_dir = args.state_dir.expanduser().resolve()
    starting = not (args.check_only or args.build_only or args.dry_run)
    try:
        share = validate_client_dir(args.client) if args.client else state_dir / "import-client"
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    print("Addon Forge — NixOS development appliance\n")
    results = check_host(state_dir, starting)
    for level, name, detail in results:
        print(f"[{level:<4}] {name:<10} {detail}")
    if any(level == "FAIL" for level, _, _ in results):
        print("\nFix failed prerequisites, or use --build-only without KVM/GUI.", file=sys.stderr)
        return 2
    print(f"\nPersistent VM state: {state_dir}")
    if args.client:
        print(f"Client to import: {share} (copied to guest disk on first boot)")
    else:
        print("Client import not supplied; use --client /path/to/WoW-3.3.5a.")
    if starting and any(c in str(share) or c in str(state_dir) for c in (" ", "\t", "\n", ",")):
        print("ERROR: client/share path cannot contain whitespace or commas in current QEMU 9p runner.", file=sys.stderr)
        return 2
    if args.check_only:
        return 0

    source = args.client_source
    if starting and source is None and args.client is None and not args.yes and sys.stdin.isatty():
        print("\nOptional: download a third-party modified WoW client from Rising Gods via BitTorrent.")
        print("This is not Blizzard's official distribution; your public IP is exposed to peers.")
        print("Proceed only if you are authorized to obtain and use this copy.")
        if input("Opt in to automatic Rising Gods download inside the VM? [y/N] ").strip().lower() in ("y", "yes"):
            source = "rising-gods"

    if args.dry_run:
        print(f"DRY RUN: nix build --no-link --print-out-paths {args.flake}#{VM_ATTR}")
        print("DRY RUN: start VM using a read-only host configuration share")
        if source:
            print(f"DRY RUN: request guest download source: {source}")
        return 0
    if starting and not args.yes:
        if not sys.stdin.isatty():
            print("ERROR: Noninteractive startup requires --yes (or --build-only).", file=sys.stderr)
            return 2
        if input("Build and start the development VM? [y/N] ").strip().lower() not in ("y", "yes"):
            print("Cancelled without changes.")
            return 0
    state_dir.mkdir(parents=True, exist_ok=True)
    if not args.client:
        share.mkdir(parents=True, exist_ok=True)
    guest_config = state_dir / "guest-config"
    if starting:
        guest_config.mkdir(mode=0o700, parents=True, exist_ok=True)
        marker = guest_config / "download-source"
        if source == "rising-gods":
            staged = guest_config / "download-source.tmp"
            staged.write_text("rising-gods\n")
            staged.replace(marker)
        elif marker.exists():
            marker.unlink()  # An earlier opt-in never overrides the current choice.
    try:
        output = build_vm(args.flake)
        runner = find_vm_runner(output)
        if args.build_only:
            print(f"VM build ready: {runner}")
            return 0
        return launch_vm(runner, state_dir, share, guest_config=guest_config)
    except (subprocess.CalledProcessError, FileNotFoundError, RuntimeError, OSError) as exc:
        print(f"ERROR: VM setup failed: {exc}", file=sys.stderr)
        return 1

if __name__ == "__main__":
    sys.exit(main())
