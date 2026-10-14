"""Reproducible, opt-in build of the external WoWControlSDK (no injection).

Only a pinned upstream commit is built. Source and binaries remain outside
the test WoW installation and Git; the existing client/realm is never changed.
Review the pinned native C++ source before opting in.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import tomllib

UPSTREAM = "https://github.com/Zerik-Official/WoWControlSDK.git"
PINNED_SHA = "6cda5ac734dba8016a7ef30ae7bcad602472c1e2"
PRODUCTS = {"wowcontrol_injector": "WowInjector.exe", "wowcontrol_dll": "WoWControlSDK.dll"}
TOOLS = ("git", "cmake")
CONFIG_KEYS = ("wowcontrol_injector", "wowcontrol_dll", "wowcontrol_realm", "automation_backend")


def _which(binary: str) -> str | None:
    found = shutil.which(binary)
    if found:
        return found
    bases = [Path(os.environ.get("ProgramFiles", "C:/Program Files")),
             Path(os.environ.get("ProgramFiles(x86)", "C:/Program Files (x86)"))]
    candidates = {
        "git": [bases[0] / "Git/cmd/git.exe"],
        "cmake": [bases[0] / "CMake/bin/cmake.exe"],
    }
    return str(next((p for p in candidates.get(binary, []) if p.is_file()), "")) or None


def _vswhere_path() -> Path:
    return Path(os.environ.get("ProgramFiles(x86)", "C:/Program Files (x86)")) / "Microsoft Visual Studio/Installer/vswhere.exe"


def _invoke(argv: list[str], *, cwd: Path | None = None, timeout: int = 180) -> str:
    try:
        proc = subprocess.run(argv, cwd=cwd, check=True, timeout=timeout,
                              text=True, capture_output=True)
        return proc.stdout.strip()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        output = getattr(exc, "stderr", "") or ""
        raise RuntimeError(f"Build command failed ({Path(argv[0]).name}): {output[-1200:]}") from exc


def _prerequisites() -> dict:
    git, cmake = _which("git"), _which("cmake")
    vswhere = _vswhere_path()
    vs = ""
    if vswhere.is_file():
        vs = _invoke([str(vswhere), "-latest", "-products", "*", "-requires",
                      "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-version", "[17.0,18.0)",
                      "-property", "installationPath"], timeout=15)
    return {"git": git, "cmake": cmake,
            "visual_studio_cpp": vs or None, "generator": "Visual Studio 17 2022",
            "platform": "Win32"}


def _install_prerequisites(tools: dict) -> None:
    """Opt-in winget installers; may prompt Windows UAC or require a restart."""
    winget = shutil.which("winget")
    if not winget:
        raise RuntimeError("winget missing; install Windows App Installer first")
    packages = [
        ("git", "Git.Git", None),
        ("cmake", "Kitware.CMake", None),
        ("visual_studio_cpp", "Microsoft.VisualStudio.2022.BuildTools",
         "--wait --quiet --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"),
    ]
    for name, package, override in packages:
        if tools.get(name):
            continue
        command = [winget, "install", "--id", package, "--exact",
                   "--source", "winget", "--silent", "--accept-package-agreements",
                   "--accept-source-agreements", "--disable-interactivity"]
        if override:
            command += ["--override", override]
        _invoke(command, timeout=3600)
    # Tool locations might not be refreshed into this PowerShell session.
    # _which checks standard installation paths as a fallback.


def _pe_machine(path: Path) -> int:
    """Ensure both compiled artifacts really target the 32-bit WoW process."""
    if not path.is_file() or path.is_symlink():
        raise RuntimeError(f"Missing regular SDK build output: {path}")
    with path.open("rb") as file:
        header = file.read(64)
        if len(header) != 64 or header[:2] != b"MZ":
            raise RuntimeError(f"Invalid Windows PE build output: {path}")
        offset = struct.unpack_from("<I", header, 60)[0]
        if offset < 64 or offset > 16 * 1024 * 1024:
            raise RuntimeError("Invalid PE header offset")
        file.seek(offset)
        pe = file.read(6)
    if len(pe) != 6 or pe[:4] != b"PE" + bytes((0, 0)):
        raise RuntimeError("Invalid PE signature")
    return struct.unpack("<H", pe[4:6])[0]


def _write_local_config(path: Path, paths: dict, realm: str | None, *, backup_dir: Path) -> bool:
    """Edit only specific existing [client] keys; never rewrite other tables."""
    if path.is_symlink() or not path.is_file():
        raise RuntimeError("Local configuration must be an existing regular file")
    content = path.read_text(encoding="utf-8")
    if len(content) > 1024 * 1024:
        raise RuntimeError("Local configuration unexpectedly large")
    original = tomllib.loads(content)
    if not isinstance(original.get("client"), dict):
        raise RuntimeError("Existing configuration has no [client] section")
    current_realm = original["client"].get("wowcontrol_realm", "")
    chosen_realm = realm if realm is not None else current_realm
    if chosen_realm and not re.fullmatch(r"[A-Za-z0-9 _-]{2,64}", chosen_realm):
        raise ValueError("Realm name must be 2-64 letters/numbers/spaces/_/-")
    values = {k: str(v).replace("\\", "/") for k, v in paths.items()}
    if chosen_realm:
        values["wowcontrol_realm"] = chosen_realm
        values["automation_backend"] = "wowcontrol"
    lines = content.splitlines(keepends=True)
    inside = False
    seen = set()
    section_end = None
    out = []
    for line in lines:
        if re.match(r"^\s*\[", line):
            if inside and section_end is None:
                section_end = len(out)
            inside = re.match(r"^\s*\[client\]\s*(?:#.*)?(?:\r?\n)?$", line) is not None
        hit = re.match(r"^(\s*)([A-Za-z_][\w-]*)\s*=", line) if inside else None
        if hit and hit.group(2) in values:
            key = hit.group(2)
            if key in seen:
                raise RuntimeError("Duplicate configuration key")
            seen.add(key)
            line = f"{hit.group(1)}{key} = {json.dumps(values[key])}\n"
        out.append(line)
    if section_end is None:
        section_end = len(out)
    additional = [f"{key} = {json.dumps(values[key])}\n" for key in values if key not in seen]
    out[section_end:section_end] = additional
    updated = "".join(out)
    tomllib.loads(updated)  # refuse malformed output
    if updated == content:
        return bool(chosen_realm)
    backup_dir.mkdir(parents=True, exist_ok=True)
    backup = backup_dir / "forge-local-toml.before-wowcontrol"
    if not backup.exists():
        if backup.is_symlink():
            raise RuntimeError("Refusing linked config backup")
        with backup.open("x", encoding="utf-8") as file:
            file.write(content)
    fd, temp = tempfile.mkstemp(prefix=".forge-config-", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as file:
            file.write(updated)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)
    return bool(chosen_realm)


def setup(config_path: Path, *, approve: bool = False, realm: str | None = None,
          workspace: Path | None = None, install_prereqs: bool = False) -> dict:
    config_path = config_path.expanduser()
    if approve and config_path.is_symlink():
        raise RuntimeError("Refusing linked local configuration")
    config_path = config_path.resolve()
    root = config_path.parent / ".forge-tools"
    if approve and root.is_symlink():
        raise RuntimeError("Refusing linked third-party tools directory")
    destination = (workspace or root / "wowcontrol-sdk").expanduser().resolve()
    if approve and not destination.is_relative_to(root.resolve()):
        raise RuntimeError("SDK workspace must be inside the ignored .forge-tools directory")
    source = destination / "source"
    binaries = source / "bin" / "release"
    preview = {"source": UPSTREAM, "revision": PINNED_SHA, "workspace": str(destination),
               "expected_artifacts": [str(binaries / p) for p in PRODUCTS.values()],
               "actions": ["clone or verify pinned SDK source", "CMake Win32 Release build",
                           "verify x86 PE artifacts", "write SDK paths to existing local TOML"],
               "note": "Compiles third-party native C++; does not install/inject/launch WoW."}
    if not approve:
        return {"status": "plan_only", "install_prereqs": install_prereqs, **preview}
    if sys.platform != "win32":
        raise RuntimeError("WoWControlSDK native builds require Windows")
    from .config import load_config
    from .win_login import _test_copy
    cfg = load_config(config_path)
    wow = _test_copy(cfg.wow_dir)
    if destination == wow or destination.is_relative_to(wow) or wow.is_relative_to(destination):
        raise RuntimeError("SDK build workspace must not overlap the test WoW installation")
    if destination.is_symlink() or source.is_symlink():
        raise RuntimeError("Refusing linked SDK build workspace")
    tools = _prerequisites()
    if install_prereqs and not all(tools[k] for k in ("git", "cmake", "visual_studio_cpp")):
        _install_prerequisites(tools)
        tools = _prerequisites()
    if not all(tools[k] for k in ("git", "cmake", "visual_studio_cpp")):
        return {"status": "missing_build_tools", **preview,
                "tools": tools,
                "hint": "Retry with --install-prereqs --approve-build to use winget; Windows may prompt for elevation or reboot."}
    git, cmake = tools["git"], tools["cmake"]
    destination.mkdir(parents=True, exist_ok=True)
    if not source.exists():
        _invoke([git, "clone", "--no-checkout", "--filter=blob:none", UPSTREAM, str(source)], timeout=240)
        _invoke([git, "-C", str(source), "fetch", "--depth", "1", "origin", PINNED_SHA], timeout=240)
        _invoke([git, "-C", str(source), "checkout", "--detach", PINNED_SHA], timeout=120)
    elif not (source / ".git").is_dir() or (source / ".git").is_symlink():
        raise RuntimeError("Existing SDK source is not a Git checkout; refusing to overwrite")
    if _invoke([git, "-C", str(source), "remote", "get-url", "origin"]) != UPSTREAM:
        raise RuntimeError("Unexpected upstream repository in SDK workspace")
    if _invoke([git, "-C", str(source), "rev-parse", "HEAD"]) != PINNED_SHA:
        raise RuntimeError("SDK checkout does not match pinned revision; refusing to build")
    if _invoke([git, "-C", str(source), "status", "--porcelain", "--untracked-files=no"]):
        raise RuntimeError("SDK tracked source files are modified; refusing to build")
    _invoke([cmake, "-S", str(source), "-B", str(source / "build"),
             "-G", "Visual Studio 17 2022", "-A", "Win32"], timeout=240)
    _invoke([cmake, "--build", str(source / "build"), "--config", "Release",
             "--parallel", "4"], timeout=1200)
    artifacts = {}
    for key, filename in PRODUCTS.items():
        p = binaries / filename
        machine = _pe_machine(p)
        if machine != 0x14c:
            raise RuntimeError(f"SDK build output is not x86 (machine={machine:#x}): {p}")
        artifacts[key] = {"path": str(p), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
    enabled = _write_local_config(config_path,
                                 {k: v["path"] for k, v in artifacts.items()}, realm,
                                 backup_dir=destination)
    return {"status": "built", "upstream_revision": PINNED_SHA, "artifacts": artifacts,
            "backend_enabled": enabled, "tools": tools,
            "next": ("Close the isolated test WoW, then run a Forge session; SDK injection is opt-in."
                     if enabled else "Build succeeded. Supply --realm-name EXACT_REALM_NAME to enable the backend.")}
