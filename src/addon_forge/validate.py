"""Basic static checks, intentionally scoped to WoW 3.3.5a."""
from dataclasses import dataclass
from pathlib import Path
import re
import shutil
import subprocess


@dataclass(frozen=True)
class Diagnostic:
    severity: str
    message: str


LEGACY_API_PATTERNS = {
    "C_Timer": r"\bC_Timer\s*\.",
    "C_UnitAuras": r"\bC_UnitAuras\s*\.",
    "Settings": r"\bSettings\s*\.",
    "Enum": r"\bEnum\s*\.",
}


def check_addon(directory: Path) -> list[Diagnostic]:
    directory = directory.resolve()
    diagnostics: list[Diagnostic] = []
    toc_files = sorted(directory.glob("*.toc"))
    if len(toc_files) != 1:
        return [Diagnostic("error", f"Expected exactly one top-level .toc, found {len(toc_files)}")]
    toc = toc_files[0]
    body = toc.read_text(encoding="utf-8-sig")
    if not re.search(r"(?im)^##\s*Interface\s*:\s*30300\s*$", body):
        diagnostics.append(Diagnostic("error", "WoW 3.3.5a requires '## Interface: 30300'"))
    files = []
    for line in body.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        ref = (directory / line.replace("\\", "/")).resolve()
        if not ref.is_relative_to(directory):
            diagnostics.append(Diagnostic("error", f"TOC path escapes addon directory: {line}"))
        elif not ref.is_file():
            diagnostics.append(Diagnostic("error", f"Missing TOC file: {line}"))
        else:
            files.append(ref)
    lua_files = list(directory.rglob("*.lua"))
    luac = shutil.which("luac5.1") or shutil.which("luac")
    for lua in lua_files:
        if lua.is_symlink():
            diagnostics.append(Diagnostic("error", f"Symlink not allowed: {lua.relative_to(directory)}"))
            continue
        text = lua.read_text(encoding="utf-8-sig")
        for name, pattern in LEGACY_API_PATTERNS.items():
            if re.search(pattern, re.sub(r"--[^\n]*", "", text)):
                diagnostics.append(Diagnostic("error", f"{lua.name}: possible unsupported API {name} on 3.3.5a"))
        if luac:
            result = subprocess.run([luac, "-p", str(lua)], capture_output=True, text=True, check=False)
            if result.returncode:
                diagnostics.append(Diagnostic("error", f"{lua.name}: {result.stderr.strip()}"))
    if not luac:
        diagnostics.append(Diagnostic("warning", "Lua compiler unavailable: run inside 'nix develop' for syntax checks"))
    if not lua_files:
        diagnostics.append(Diagnostic("warning", "No Lua files found"))
    return diagnostics


def is_valid(diagnostics: list[Diagnostic]) -> bool:
    return all(d.severity != "error" for d in diagnostics)
