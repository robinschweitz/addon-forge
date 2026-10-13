"""Private AzerothCore SSH forwarding and safe local WoW realm configuration.

Neither operation exposes game ports on the public internet. Requires a
trusted SSH host key and an interactive local WoW installation.
"""
from __future__ import annotations

import ipaddress
from pathlib import Path
import re
import shutil
import subprocess

PORTS = (3724, 8085)


def _host(value: str) -> str:
    if not isinstance(value, str) or not value or value.startswith("-"):
        raise ValueError("Provide the server's IPv4 address or DNS hostname")
    try:
        return str(ipaddress.IPv4Address(value))
    except ipaddress.AddressValueError:
        if (len(value) > 253 or not re.fullmatch(
            r"[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?", value
        ) or ".." in value or "." not in value):
            raise ValueError("Invalid SSH host. Use a public IPv4 or DNS hostname")
    return value


def ssh_tunnel_command(host: str, *, user: str = "root",
                       identity: Path | None = None, port: int = 22) -> list[str]:
    host = _host(host)
    if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", user):
        raise ValueError("Invalid SSH username")
    if not isinstance(port, int) or not 1 <= port <= 65535:
        raise ValueError("Invalid SSH port")
    args = ["ssh", "-N", "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=yes", "-p", str(port)]
    if identity is not None:
        key = identity.expanduser().resolve(strict=True)
        if not key.is_file():
            raise FileNotFoundError(key)
        args.extend(["-i", str(key)])
    for forwarded_port in PORTS:
        args.extend(["-L", f"127.0.0.1:{forwarded_port}:127.0.0.1:{forwarded_port}"])
    args.append(f"{user}@{host}")
    return args


def tunnel(host: str, *, user: str = "root",
           identity: Path | None = None, port: int = 22) -> int:
    if not shutil.which("ssh"):
        raise RuntimeError("OpenSSH client missing. Install it on Windows/Linux")
    command = ssh_tunnel_command(host, user=user, identity=identity, port=port)
    print("Private AzerothCore tunnel; ports 3724 and 8085 forwarded to localhost.")
    print("Keep this terminal open while playing/testing; Ctrl+C closes the tunnel.")
    print("Verify the SSH server fingerprint before trusting it.")
    try:
        return subprocess.run(command, check=False).returncode
    except KeyboardInterrupt:
        return 130


def configure_realmlist(wow_dir: Path, *, locale: str | None = None) -> tuple[Path, Path]:
    """Set local client's login address to the SSH tunnel, preserving original."""
    wow_dir = wow_dir.expanduser().resolve()
    if not any((wow_dir / exe).is_file() for exe in ("Wow.exe", "WoW.exe")):
        raise FileNotFoundError(f"No WoW executable under {wow_dir}")
    data = wow_dir / "Data"
    if locale is not None and not re.fullmatch(r"[A-Za-z]{2}[A-Za-z]{2}", locale):
        raise ValueError("Locale must look like enUS or deDE")
    if locale:
        candidates = [data / locale / "realmlist.wtf"]
    else:
        candidates = sorted(data.glob("????/realmlist.wtf"))
    # Never silently create an unknown localization or edit multiple installs.
    candidates = [p for p in candidates if p.is_file() and not p.is_symlink()]
    if len(candidates) != 1:
        raise RuntimeError(
            "Expected exactly one Data/<locale>/realmlist.wtf. "
            "Choose one with --locale enUS (or deDE, enGB, etc.)."
        )
    target = candidates[0]
    if not target.resolve().is_relative_to(wow_dir):
        raise RuntimeError("WoW realmlist path escapes the selected client directory")
    backup = target.with_name("realmlist.wtf.forge-backup")
    # Refuse to overwrite an existing backup, unless the client is already
    # correctly configured. The original can always be restored manually.
    original = target.read_bytes()
    try:
        content = original.decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        raise RuntimeError("Realmlist is not UTF-8; edit it manually") from exc
    changed, count = re.subn(
        r"(?im)^\s*set\s+realmlist\s+[^\r\n]*",
        "set realmlist 127.0.0.1",
        content,
    )
    if count > 1:
        raise RuntimeError("Several realmlist directives found; edit manually")
    if count == 0:
        changed = "set realmlist 127.0.0.1\n" + content
    if changed == content:
        return target, backup
    if backup.exists():
        raise RuntimeError(
            f"Existing backup {backup}; restore or move it before making another change"
        )
    with backup.open("xb") as out:
        out.write(original)
    target.write_bytes(changed.encode("utf-8"))
    return target, backup
