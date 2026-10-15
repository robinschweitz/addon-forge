"""Static checks, intentionally scoped to WoW 3.3.5a (Lua 5.1, Interface 30300)."""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
import re
import xml.etree.ElementTree as ET

from . import wowapi
from .lua51 import global_accesses, syntax_error

# Folders that hold offline specs or evidence, never loaded by the client.
NON_CLIENT_DIRS = {"tests", ".forge-runs"}


@dataclass(frozen=True)
class Diagnostic:
    severity: str
    message: str


@dataclass
class Toc:
    path: Path
    interface: str | None
    files: list[Path]
    saved_variables: list[str] = field(default_factory=list)


def read_toc(directory: Path, diagnostics: list[Diagnostic] | None = None) -> Toc | None:
    diagnostics = diagnostics if diagnostics is not None else []
    directory = directory.resolve()
    toc_files = sorted(directory.glob("*.toc"))
    if len(toc_files) != 1:
        diagnostics.append(Diagnostic("error", f"Expected exactly one top-level .toc, found {len(toc_files)}"))
        return None
    toc = toc_files[0]
    body = toc.read_text(encoding="utf-8-sig")
    interface = re.search(r"(?im)^##\s*Interface\s*:\s*(\S+)\s*$", body)
    saved = []
    for match in re.finditer(r"(?im)^##\s*SavedVariables(?:PerCharacter)?\s*:\s*(.+)$", body):
        saved += [n.strip() for n in match.group(1).split(",") if n.strip()]
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
    return Toc(toc, interface.group(1) if interface else None, files, saved)


def _xml_lua_files(xml: Path, directory: Path, diagnostics: list[Diagnostic]) -> list[Path]:
    """Validate an XML file's well-formedness and its <Script>/<Include> file references."""
    try:
        root = ET.parse(xml).getroot()
    except ET.ParseError as exc:
        diagnostics.append(Diagnostic("error", f"{xml.name}: malformed XML: {exc}"))
        return []
    found = []
    for node in root.iter():
        tag = node.tag.rsplit("}", 1)[-1]
        target = node.get("file")
        if tag not in ("Script", "Include") or not target:
            continue
        ref = (xml.parent / target.replace("\\", "/")).resolve()
        if not ref.is_relative_to(directory) or not ref.is_file():
            diagnostics.append(Diagnostic("error", f"{xml.name}: missing {tag} file {target}"))
        elif ref.suffix.lower() == ".lua":
            found.append(ref)
        elif ref.suffix.lower() == ".xml":
            found += _xml_lua_files(ref, directory, diagnostics)
    return found


def load_order(directory: Path, diagnostics: list[Diagnostic] | None = None) -> list[Path]:
    """Lua files in the order the client executes them (TOC order, XML scripts inlined)."""
    diagnostics = diagnostics if diagnostics is not None else []
    directory = directory.resolve()
    toc = read_toc(directory, diagnostics)
    if toc is None:
        return []
    order = []
    for ref in toc.files:
        if ref.suffix.lower() == ".lua":
            order.append(ref)
        elif ref.suffix.lower() == ".xml":
            order += _xml_lua_files(ref, directory, diagnostics)
    return order


def _api_diagnostics(lua: Path, rel: str, accesses, defined: set[str],
                     dump: frozenset[str] | None) -> list[Diagnostic]:
    out = []
    reported = set()
    for access in accesses:
        where = f"{rel}:{access.line}"
        if access.kind == "method":
            hint = wowapi.MODERN_METHODS.get(access.method)
            key = ("m", access.method)
            if hint and key not in reported:
                reported.add(key)
                out.append(Diagnostic("error", f"{where}: :{access.method}() is not in 3.3.5a. {hint}"))
            continue
        name = access.name
        if access.kind == "get":
            hint = wowapi.LUA52_FIELDS.get((name, access.field))
            if hint and (name, access.field) not in reported:
                reported.add((name, access.field))
                out.append(Diagnostic("error", f"{where}: {hint}"))
                continue
        if name in defined and not wowapi.modern_global(name):
            continue
        hint = wowapi.modern_global(name)
        if hint and name not in reported:
            reported.add(name)
            out.append(Diagnostic("error", f"{where}: {name} is not available on 3.3.5a. {hint}"))
        elif access.kind == "get" and dump is not None and name not in dump \
                and name not in wowapi.LUA51_GLOBALS and name not in reported:
            reported.add(name)
            out.append(Diagnostic("warning", f"{where}: unknown global {name!r} (not defined by this "
                                             "addon and not in the 3.3.5a client dump)"))
    return out


def check_addon(directory: Path) -> list[Diagnostic]:
    directory = directory.resolve()
    diagnostics: list[Diagnostic] = []
    toc = read_toc(directory, diagnostics)
    if toc is None:
        return diagnostics
    if toc.interface != "30300":
        diagnostics.append(Diagnostic("error", "WoW 3.3.5a requires '## Interface: 30300'"))
    order = load_order(directory, diagnostics)
    lua_files = [p for p in directory.rglob("*.lua")
                 if not NON_CLIENT_DIRS & set(p.relative_to(directory).parts[:-1])]
    for unlisted in sorted(set(lua_files) - set(order)):
        diagnostics.append(Diagnostic("warning", f"{unlisted.relative_to(directory)} is not loaded by the .toc"))
    parsed = {}
    for lua in lua_files:
        rel = lua.relative_to(directory).as_posix()
        if lua.is_symlink():
            diagnostics.append(Diagnostic("error", f"Symlink not allowed: {rel}"))
            continue
        source = lua.read_bytes().removeprefix(b"\xef\xbb\xbf")
        error = syntax_error(source, rel)
        if error:
            diagnostics.append(Diagnostic("error", f"Lua 5.1 syntax: {error}"))
            continue
        parsed[lua] = (rel, global_accesses(source, rel))
    # Globals any file of this addon assigns count as defined for all files.
    defined = set(toc.saved_variables)
    for rel, accesses in parsed.values():
        defined |= {a.name for a in accesses if a.kind == "set"}
    dump = wowapi.known_globals()
    for lua, (rel, accesses) in parsed.items():
        diagnostics += _api_diagnostics(lua, rel, accesses, defined, dump)
        for access in accesses:
            if (access.kind == "set" and re.fullmatch(r"[a-z][a-z0-9]{0,5}", access.name)
                    and access.name not in toc.saved_variables):
                diagnostics.append(Diagnostic("warning", f"{rel}:{access.line}: assigns global "
                                                         f"{access.name!r}; missing 'local'?"))
    if not lua_files:
        diagnostics.append(Diagnostic("warning", "No Lua files found"))
    if dump is None:
        diagnostics.append(Diagnostic("info", "No 3.3.5a client global dump; only known-modern APIs are "
                                              "checked. Run 'forge api dump' once for full coverage."))
    return diagnostics


def is_valid(diagnostics: list[Diagnostic]) -> bool:
    return all(d.severity != "error" for d in diagnostics)
