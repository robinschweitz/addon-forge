"""Run an addon and its offline specs in the headless 3.3.5a emulation.

Specs live in ``<Addon>/tests/*.spec.lua`` (never deployed to the client)::

    before_load(function()
        forge.setSaved("MyAddonDB", { count = 2 })    -- seed SavedVariables
    end)

    test("toggles the window", function()
        forge.slash("/myaddon")
        expect("MyAddonFrame").toBeHidden()
    end)

Each spec file gets a fresh world. Tests in one file share state, in order.
Offline results are fast feedback, not acceptance: the real-client plan stays
the final gate. Addon code runs in a sandbox with no os/io/Python access, an
instruction budget and a memory cap.
"""
from __future__ import annotations

import json
from pathlib import Path
import re

from .. import wowapi
from ..lua51 import global_accesses
from ..validate import load_order, read_toc

HARNESS = Path(__file__).with_name("wow.lua")
MEMORY_LIMIT = 256 * 1024 * 1024


def _b(value):
    if isinstance(value, str):
        return value.encode("utf-8")
    if isinstance(value, dict):
        return {_b(k): _b(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_b(v) for v in value]
    return value


def _to_lua(lua, value):
    value = _b(value)
    if isinstance(value, dict):
        table = lua.table()
        for k, v in value.items():
            table[k] = _to_lua(lua, v)
        return table
    if isinstance(value, list):
        table = lua.table()
        for i, v in enumerate(value, 1):
            table[i] = _to_lua(lua, v)
        return table
    return value


def _metadata(toc_path: Path) -> dict:
    meta = {}
    for line in toc_path.read_text(encoding="utf-8-sig").splitlines():
        m = re.match(r"##\s*([\w-]+)\s*:\s*(.*)$", line.strip())
        if m:
            meta[m.group(1)] = m.group(2).strip()
    return meta


def _listify(value):
    return value if isinstance(value, list) else []


# Optional companion addons an addon may probe for with `if X and ...`.
OPTIONAL_GLOBALS = frozenset({"ForgeTestBridge"})


def _all_errors(raw: dict) -> str:
    texts = _listify(raw.get("load_errors")) + _listify(raw.get("errors"))
    for test in _listify(raw.get("tests")):
        texts += [test.get("error") or ""] + _listify(test.get("errors"))
    return "\n".join(t for t in texts if isinstance(t, str))


def _classify(raw: dict, defined: set[str]) -> list[dict]:
    """Turn harness observations into diagnostics with 3.3.5a-aware severity."""
    notes = []
    errors = _all_errors(raw)
    dump = wowapi.known_globals()
    nil_globals = raw.get("nil_globals") if isinstance(raw.get("nil_globals"), dict) else {}
    for name, where in sorted(nil_globals.items()):
        if name in defined or name in OPTIONAL_GLOBALS:
            continue
        hint = wowapi.modern_global(name)
        if hint:
            notes.append({"severity": "error", "where": where, "message": f"{name} does not exist on 3.3.5a. {hint}"})
        elif dump is not None and name not in dump:
            notes.append({"severity": "warning", "where": where,
                          "message": f"{name} is not a 3.3.5a global (nil in the real client too, unless another addon defines it)"})
        else:
            notes.append({"severity": "info", "where": where,
                          "message": f"{name} is not emulated offline; stub it with forge.stub({name!r}, ...) if the spec needs it"})
    missing = raw.get("missing_methods") if isinstance(raw.get("missing_methods"), dict) else {}
    for label, where in sorted(missing.items()):
        method = label.split(":", 1)[1]
        if f"attempt to call method '{method}'" in errors:
            notes.append({"severity": "error", "where": where,
                          "message": f"{label}() does not exist on 3.3.5a (client method dump)"})
        else:  # Only read, e.g. `if frame.GetText then`: nil, as in the real client.
            notes.append({"severity": "info", "where": where,
                          "message": f"{label} is nil on 3.3.5a; read here without being called"})
    methods = raw.get("unemulated_methods") if isinstance(raw.get("unemulated_methods"), dict) else {}
    for label, where in sorted(methods.items()):
        notes.append({"severity": "info", "where": where,
                      "message": f"{label} is not emulated offline (no-op returning nil); "
                                 "verify it exists on this widget type in 3.3.5a"})
    templates = raw.get("unknown_templates") if isinstance(raw.get("unknown_templates"), dict) else {}
    for name, where in sorted(templates.items()):
        notes.append({"severity": "info", "where": where,
                      "message": f"Template {name!r} is not modelled offline; verify it exists in 3.3.5a FrameXML"})
    return notes


SKETCH_NAME = re.compile(r"[A-Za-z0-9_-]{1,40}")


def _rgb(color, default=(0, 0, 0, 1)) -> tuple[str, float]:
    c = [float(v) for v in (color if isinstance(color, list) else default)][:4] + [1.0]
    return "#%02x%02x%02x" % tuple(round(max(0.0, min(1.0, v)) * 255) for v in c[:3]), max(0.0, min(1.0, c[3]))


def sketch_svg(sketch: dict) -> str:
    """An SVG picture of one forge.sketch() capture (estimated fonts, no texture files)."""
    w, h = float(sketch.get("width") or 1), float(sketch.get("height") or 1)
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w * 2:.0f}" height="{h * 2:.0f}" '
           f'viewBox="0 0 {w:.1f} {h:.1f}" font-family="Arial Narrow, Arial, sans-serif">',
           f'<rect width="{w:.1f}" height="{h:.1f}" fill="#3a4a2a"/>']
    for i, item in enumerate(_listify(sketch.get("items"))):
        x, y, iw, ih = (float(item.get(k) or 0) for k in ("x", "y", "w", "h"))
        if item.get("kind") == "box":
            fill, alpha = _rgb(item.get("color"))
            border = item.get("border")
            stroke = ""
            if isinstance(border, list):
                col, balpha = _rgb(border)
                stroke = f' stroke="{col}" stroke-opacity="{balpha:.2f}" stroke-width="1"'
            out.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{iw:.1f}" height="{ih:.1f}" '
                       f'fill="{fill}" fill-opacity="{alpha:.2f}"{stroke}/>')
        elif item.get("kind") == "text":
            fill, _ = _rgb(item.get("color"), (1, 0.82, 0, 1))
            size = float(item.get("size") or 12)
            justify = item.get("justify") or "CENTER"
            anchor, tx = {"LEFT": ("start", x), "RIGHT": ("end", x + iw)}.get(justify, ("middle", x + iw / 2))
            clip = ""
            if item.get("clip"):
                out.append(f'<clipPath id="c{i}"><rect x="{x:.1f}" y="{y:.1f}" width="{iw:.1f}" height="{ih:.1f}"/></clipPath>')
                clip = f' clip-path="url(#c{i})"'
            lines = str(item.get("text", "")).split("\n")
            top = y + (ih - size * len(lines)) / 2
            for n, line in enumerate(lines):
                text = line.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
                out.append(f'<text x="{tx:.1f}" y="{top + size * (n + 0.8):.1f}" font-size="{size:.1f}" '
                           f'fill="{fill}" text-anchor="{anchor}"{clip}>{text}</text>')
    out.append("</svg>")
    return "\n".join(out)


def _save_sketches(raw: dict, addon_dir: Path) -> list[str]:
    """Write each forge.sketch() capture to .forge-runs/sketches beside the addon."""
    paths = []
    for sketch in _listify(raw.get("sketches")):
        name = str(sketch.get("name", ""))
        if not SKETCH_NAME.fullmatch(name):
            continue
        folder = addon_dir.parent / ".forge-runs" / "sketches"
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / f"{addon_dir.name}-{name}.svg"
        path.write_text(sketch_svg(sketch), encoding="utf-8")
        paths.append(str(path))
    return paths


def run_addon(addon_dir: Path, spec: Path | None = None, *, budget: int = 20_000_000) -> dict:
    """Load the addon (and optionally one spec file) in a fresh headless world."""
    import lupa.lua51 as lua51

    addon_dir = addon_dir.resolve()
    diagnostics = []
    toc = read_toc(addon_dir, diagnostics)
    if toc is None:
        return {"status": "failed", "load_errors": [d.message for d in diagnostics], "tests": []}
    order = load_order(addon_dir, diagnostics)
    lua = lua51.LuaRuntime(encoding=None, register_eval=False, register_builtins=False,
                           unpack_returned_tuples=True, max_memory=MEMORY_LIMIT)
    loader = lua.globals().loadstring(HARNESS.read_bytes(), b"@wow.lua")
    if isinstance(loader, tuple):
        raise RuntimeError(f"Harness failed to compile: {loader[1]!r}")
    harness = loader()
    harness.budget = budget
    config = {"addonName": addon_dir.name, "metadata": _metadata(toc.path),
              "savedVariables": toc.saved_variables}
    methods = wowapi.known_methods()
    if methods:
        config["methods"] = {kind: {name: True for name in names} for kind, names in methods.items()}
    files = [{"name": p.relative_to(addon_dir).as_posix(),
              "source": p.read_bytes().removeprefix(b"\xef\xbb\xbf")} for p in order]
    spec_source = spec.read_bytes().removeprefix(b"\xef\xbb\xbf") if spec else None
    spec_name = spec.relative_to(addon_dir).as_posix().encode() if spec else None
    try:
        raw_json = harness.run(_to_lua(lua, config), _to_lua(lua, files), spec_source, spec_name)
    except lua51.LuaMemoryError:
        return {"status": "failed", "spec": spec_name and spec_name.decode(),
                "load_errors": [f"Memory limit of {MEMORY_LIMIT // (1024 * 1024)} MB exceeded"], "tests": []}
    raw = json.loads(raw_json.decode("utf-8", "replace"))
    tests = _listify(raw.get("tests"))
    for t in tests:
        t["errors"] = _listify(t.get("errors"))
    defined = set(toc.saved_variables)
    for f in files:
        try:
            defined |= {a.name for a in global_accesses(f["source"], f["name"]) if a.kind == "set"}
        except SyntaxError:
            pass  # Already reported as a load error.
    notes = _classify(raw, defined)
    load_errors = [d.message for d in diagnostics if d.severity == "error"] + _listify(raw.get("load_errors"))
    errors = _listify(raw.get("errors"))
    failed = (load_errors or errors or any(t.get("status") != "passed" for t in tests)
              or any(n["severity"] == "error" for n in notes))
    return {"status": "failed" if failed else "passed",
            "spec": spec_name.decode() if spec_name else None,
            "load_errors": load_errors, "errors": errors, "tests": tests, "diagnostics": notes,
            "chat": _listify(raw.get("chat"))[-30:], "sent": _listify(raw.get("sent"))[-30:],
            "sketches": _save_sketches(raw, addon_dir)}


def spec_files(addon_dir: Path) -> list[Path]:
    return sorted((addon_dir / "tests").glob("*.spec.lua")) if (addon_dir / "tests").is_dir() else []


def run_specs(addon_dir: Path) -> dict:
    """Load smoke plus every spec file. Each spec runs in its own fresh world."""
    addon_dir = addon_dir.resolve()
    runs = [run_addon(addon_dir)]
    runs += [run_addon(addon_dir, spec) for spec in spec_files(addon_dir)]
    tests = sum(len(r["tests"]) for r in runs)
    passed = sum(1 for r in runs for t in r["tests"] if t.get("status") == "passed")
    return {"status": "passed" if all(r["status"] == "passed" for r in runs) else "failed",
            "addon": addon_dir.name, "specs": len(runs) - 1, "tests": tests, "passed": passed,
            "runs": runs,
            "note": "Offline emulation: fast feedback, not proof of in-client behaviour."}
