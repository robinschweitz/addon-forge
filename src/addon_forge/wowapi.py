"""What exists in the WoW 3.3.5a (build 12340) Lua environment.

Sources, in order of authority:

1. ``wow/api/globals-30300.txt`` -- the real ``_G`` key list dumped from the
   isolated test client with ``forge api dump``. When present, any global an
   addon reads that is neither in this list nor defined by the addon itself is
   reported, which catches hallucinated APIs directly.
2. ``.forge-tools/wowdecomp`` -- an optional local C++ decompilation of build
   12340. Its script registration tables give the native Lua globals, widget
   methods and complete event list. The index stores only names and source
   locations; it never copies decompiled code or is committed.
3. The built-in lists below, used whether or not a dump exists. They name only
   APIs that are known to be absent from 3.3.5a (added in later expansions, or
   Lua 5.2+), so an error from them is high-confidence.

Lookups also attach signatures and event payloads from a local copy of the
MilkyWay Codex data (``.forge-tools/milkyway-codex``, not committed: it has no
licence). It never decides whether something exists when a dump does, and its
``protected``/``hwEvent`` flags are ignored: they are wrong for 3.3.5a
(CalendarAddEvent, SendChatMessage).
"""
from __future__ import annotations

from functools import lru_cache
import json
from pathlib import Path
import re

DUMP_PATH = Path(__file__).resolve().parents[2] / "wow" / "api" / "globals-30300.txt"
CODEX_DIR = Path(__file__).resolve().parents[2] / ".forge-tools" / "milkyway-codex"
DECOMP_DIR = Path(__file__).resolve().parents[2] / ".forge-tools" / "wowdecomp"

# Lua 5.1 base library plus the extra globals WoW 3.3.5a adds to every
# environment. Used so a missing dump never flags these as unknown.
LUA51_GLOBALS = frozenset("""
_G _VERSION assert collectgarbage error getfenv getmetatable ipairs load
loadstring next pairs pcall print rawequal rawget rawset select setfenv
setmetatable tonumber tostring type unpack xpcall gcinfo newproxy
coroutine math string table bit
strbyte strchar strfind strformat strlen strlower strmatch strrep strrev strsub
strupper gmatch gsub format tinsert tremove sort getn foreach foreachi
abs ceil floor max min mod sqrt random exp log log10 frexp ldexp
cos sin tan acos asin atan atan2 deg rad PI
strsplit strjoin strtrim strconcat tostringall wipe date time difftime
debugstack debugprofilestart debugprofilestop issecurevariable securecall
hooksecurefunc geterrorhandler seterrorhandler scrub
""".split())

# Not available in the WoW sandbox at all.
SANDBOX_MISSING = {
    "io": "WoW has no file I/O; persist data with ## SavedVariables",
    "require": "WoW has no module loader; list files in the .toc in load order",
    "dofile": "WoW cannot load files at runtime; list them in the .toc",
    "loadfile": "WoW cannot load files at runtime; list them in the .toc",
    "module": "Lua 5.1 module() is unavailable in WoW",
    "package": "WoW has no package library",
    "bit32": "bit32 is Lua 5.2; WoW 3.3.5a provides the 'bit' library",
    "utf8": "utf8 is Lua 5.3",
}

# Fields of standard tables that are Lua 5.2+ only.
LUA52_FIELDS = {
    ("table", "unpack"): "table.unpack is Lua 5.2; use unpack()",
    ("table", "pack"): "table.pack is Lua 5.2; use {...} and select('#', ...)",
    ("string", "pack"): "string.pack is Lua 5.3",
    ("string", "unpack"): "string.unpack is Lua 5.3",
    ("math", "tointeger"): "math.tointeger is Lua 5.3",
    ("math", "type"): "math.type is Lua 5.3",
}

# Globals added after Wrath. Each maps to a hint for the 3.3.5a equivalent.
MODERN_GLOBALS = {
    "Enum": "Enum tables were added in 8.0",
    "Mixin": "Mixin() was added after 3.3.5a; copy fields manually",
    "CreateFromMixins": "Mixins were added after 3.3.5a",
    "CreateAndInitFromMixin": "Mixins were added after 3.3.5a",
    "BackdropTemplateMixin": "3.3.5a frames support SetBackdrop directly; no template needed",
    "Settings": "The Settings panel API was added in 10.0; use InterfaceOptions_AddCategory",
    "SOUNDKIT": "SOUNDKIT ids were added in 7.3; PlaySound takes sound names on 3.3.5a",
    "IsInGroup": "Added in 5.0; use GetNumPartyMembers() > 0 or GetNumRaidMembers() > 0",
    "IsInRaid": "Added in 5.0; use GetNumRaidMembers() > 0",
    "GetNumGroupMembers": "Added in 5.0; use GetNumRaidMembers() / GetNumPartyMembers()",
    "GetNumSubgroupMembers": "Added in 5.0; use GetNumPartyMembers()",
    "UnitIsGroupLeader": "Added in 5.0; use IsPartyLeader() / IsRaidLeader()",
    "UnitIsGroupAssistant": "Added in 5.0; use IsRaidOfficer()",
    "GetSpecialization": "Specializations were added in 5.0; use GetPrimaryTalentTree()",
    "GetSpecializationInfo": "Specializations were added in 5.0",
    "Ambiguate": "Added in 5.1; 3.3.5a names have no realm suffix to strip",
    "GetItemInfoInstant": "Added in 7.0; use GetItemInfo()",
    "GetTimePreciseSec": "Added after 3.3.5a; use GetTime() or debugprofilestop()",
    "strsplittable": "Added after 3.3.5a; use { strsplit(...) }",
    "CreateColor": "Color mixins were added after 3.3.5a; use r, g, b values",
    "WrapTextInColorCode": "Added after 3.3.5a; build '|cffRRGGBB...|r' strings",
    "CreateScrollBoxListLinearView": "ScrollBox was added in 9.x; use FauxScrollFrame",
    "ScrollUtil": "ScrollBox was added in 9.x; use FauxScrollFrame",
}

# Widget methods added after Wrath (high confidence only).
MODERN_METHODS = {
    "SetColorTexture": "Added in 7.0; use SetTexture(r, g, b, a) on 3.3.5a",
    "SetResizeBounds": "Added in 10.0; use SetMinResize / SetMaxResize",
    "SetAtlas": "Texture atlases are not available on 3.3.5a",
    "RegisterUnitEvent": "Added in 5.0; RegisterEvent and filter the unit argument",
}

# Events the 3.3.5a client does not have (checked against the 12340 client's
# event table). RegisterEvent ignores unknown names silently, so a frame
# waiting for one of these never runs in the real client.
MODERN_EVENTS = {
    "GROUP_ROSTER_UPDATE": "Added in 5.0; use PARTY_MEMBERS_CHANGED and RAID_ROSTER_UPDATE",
    "GROUP_JOINED": "Added in 5.x; watch PARTY_MEMBERS_CHANGED / RAID_ROSTER_UPDATE",
    "GROUP_LEFT": "Added in 5.x; watch PARTY_MEMBERS_CHANGED / RAID_ROSTER_UPDATE",
    "PLAYER_SPECIALIZATION_CHANGED": "Added in 5.0; use ACTIVE_TALENT_GROUP_CHANGED / PLAYER_TALENT_UPDATE",
    "CHAT_MSG_ADDON_LOGGED": "Added in 7.x; 3.3.5a only has CHAT_MSG_ADDON",
    "LOADING_SCREEN_DISABLED": "Added after 3.3.5a; use PLAYER_ENTERING_WORLD",
    "LOADING_SCREEN_ENABLED": "Added after 3.3.5a; use PLAYER_LEAVING_WORLD",
    "ENCOUNTER_START": "Added in 5.x; 3.3.5a has INSTANCE_ENCOUNTER_ENGAGE_UNIT",
    "ENCOUNTER_END": "Added in 5.x; watch the boss's death in COMBAT_LOG_EVENT_UNFILTERED",
    "UNIT_POWER": "Added in 4.0; use UNIT_MANA, UNIT_RAGE, UNIT_ENERGY, UNIT_RUNIC_POWER",
    "UNIT_POWER_FREQUENT": "Added in 4.x; use UNIT_MANA and the other per-power events",
    "UNIT_HEALTH_FREQUENT": "Added after 3.3.5a; use UNIT_HEALTH",
    "BAG_UPDATE_DELAYED": "Added in 5.x; use BAG_UPDATE",
    "GET_ITEM_INFO_RECEIVED": "Added in 4.x; poll GetItemInfo or wait for an item to be cached",
    "ITEM_DATA_LOAD_RESULT": "Added in 8.x; poll GetItemInfo",
    "LOOT_READY": "Added in 5.x; use LOOT_OPENED",
    "GROUP_INVITE_CONFIRMATION": "Added in 5.x; 3.3.5a has PARTY_INVITE_REQUEST",
    "UI_SCALE_CHANGED": "Added after 3.3.5a; use DISPLAY_SIZE_CHANGED",
    "PET_BATTLE_OPENING_START": "Pet battles were added in 5.0",
}

MODERN_PREFIX = re.compile(r"C_[A-Z]")  # C_ namespaces did not exist in 3.3.5a


@lru_cache(maxsize=4)
def _load_dump(path: Path) -> tuple[frozenset[str], dict[str, frozenset[str]]] | None:
    if not path.is_file():
        return None
    names, methods = set(), {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if ":" in line:
            widget, method = line.split(":", 1)
            methods.setdefault(widget, set()).add(method)
        else:
            names.add(line)
    return frozenset(names), {k: frozenset(v) for k, v in methods.items()}


def known_globals(path: Path | None = None) -> frozenset[str] | None:
    """The dumped 3.3.5a global list, or None when no dump has been taken yet."""
    dump = _load_dump(path or DUMP_PATH)
    return dump[0] if dump else None


def known_methods(path: Path | None = None) -> dict[str, frozenset[str]]:
    """Widget type -> method names dumped from the client (empty without a dump)."""
    dump = _load_dump(path or DUMP_PATH)
    return dump[1] if dump else {}


_METHOD_ARRAY = re.compile(r"(?:static\s+)?FrameScript_Method\s+(\w+)\s*\[\]\s*=\s*\{(.*?)\};", re.S)
_METHOD_ENTRY = re.compile(r'\{\s*"([A-Za-z_][A-Za-z0-9_]*)"\s*,\s*&([A-Za-z_][A-Za-z0-9_]*)')
_GLOBAL_REGISTRATION = re.compile(r"FrameScript_RegisterFunction\(\s*(\w+)\s*\[")
_DIRECT_GLOBAL_REGISTRATION = re.compile(r'FrameScript_RegisterFunction\(\s*"([A-Za-z_][A-Za-z0-9_]*)"\s*,\s*&([A-Za-z_][A-Za-z0-9_]*)')
_METHOD_OWNER = re.compile(r"void\s+([A-Za-z_][A-Za-z0-9_]*)::RegisterScriptMethods\s*\(")
_FACTORY = re.compile(r'FrameXML_RegisterFactory\("([A-Za-z][A-Za-z0-9]*)",\s*(Create_[A-Za-z0-9_]+),')
_FACTORY_IMPL = re.compile(r"CSimpleFrame\*\s+(Create_[A-Za-z0-9_]+)\s*\([^)]*\)\s*\{.*?new(?:\s*\([^)]*\))?\s*([A-Za-z_][A-Za-z0-9_]*)\(", re.S)
_EVENT = re.compile(r"\bEVENT\(([A-Z][A-Z0-9_]*),")
_EVENT_ALIAS = re.compile(r'\bEVENT_ALIAS\([A-Z][A-Z0-9_]*,\s*"([A-Z][A-Z0-9_]*)"')

# Regions are not created through FrameXML_RegisterFactory, and a few common
# XML types use a more specialised class. The native metatable still supplies
# their methods.
_WIDGET_CLASSES = {
    "Font": "CSimpleFont",
    "FontString": "CSimpleFontString",
    "Texture": "CSimpleTexture",
    "GameTooltip": "CGTooltip",
    "PlayerModel": "CSimpleModel",
}


def _source_location(root: Path, path: Path, text: str, offset: int) -> dict:
    return {"source": "wowdecomp-12340", "path": path.relative_to(root).as_posix(),
            "line": text.count("\n", 0, offset) + 1}


@lru_cache(maxsize=2)
def _load_decomp(root: Path) -> dict:
    """Index native Lua registrations in a local 12340 decompilation.

    The index contains API names and source locations only. Runtime dumps stay
    authoritative because FrameXML can also create Lua globals and because
    some registrations depend on the client's current screen.
    """
    if not root.is_dir():
        return {"functions": {}, "methods": {}, "events": frozenset()}
    functions, class_methods, parents, factories = {}, {}, {}, {}
    for path in root.rglob("*.cpp"):
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        arrays = {match.group(1): (match.group(2), match.start()) for match in _METHOD_ARRAY.finditer(text)}
        for array, (body, offset) in arrays.items():
            entries = _METHOD_ENTRY.findall(body)
            if not entries:
                continue
            tail = text[offset:]
            if _GLOBAL_REGISTRATION.search(tail) and _GLOBAL_REGISTRATION.search(tail).group(1) == array:
                for name, symbol in entries:
                    functions[name] = {**_source_location(root, path, text, offset), "symbol": symbol}
            else:
                owner = _METHOD_OWNER.search(tail)
                if owner:
                    class_methods.setdefault(owner.group(1), {}).update({name: symbol for name, symbol in entries})
        owners = list(_METHOD_OWNER.finditer(text))
        for i, owner in enumerate(owners):
            end = owners[i + 1].start() if i + 1 < len(owners) else len(text)
            parent = re.search(r"\b([A-Za-z_][A-Za-z0-9_]*)::RegisterScriptMethods\s*\(\s*L\s*\)",
                               text[owner.end():end])
            if parent and parent.group(1) != owner.group(1):
                parents[owner.group(1)] = parent.group(1)
        for match in _DIRECT_GLOBAL_REGISTRATION.finditer(text):
            functions[match.group(1)] = {**_source_location(root, path, text, match.start()), "symbol": match.group(2)}
    frame_xml = root / "Engine" / "Source" / "FrameXML" / "FrameXML.cpp"
    try:
        text = frame_xml.read_text(encoding="utf-8")
    except OSError:
        text = ""
    implementations = {match.group(1): match.group(2) for match in _FACTORY_IMPL.finditer(text)}
    for match in _FACTORY.finditer(text):
        implementation = implementations.get(match.group(2))
        if implementation:
            factories[match.group(1)] = implementation
    factories.update(_WIDGET_CLASSES)
    def inherited_methods(implementation: str, seen=None) -> dict:
        seen = seen or set()
        if implementation in seen:
            return {}
        seen.add(implementation)
        inherited = inherited_methods(parents[implementation], seen) if implementation in parents else {}
        inherited.update(class_methods.get(implementation, {}))
        return inherited

    methods = {}
    for widget, implementation in factories.items():
        available = inherited_methods(implementation)
        if available:
            methods[widget] = {name: {"symbol": symbol} for name, symbol in available.items()}
    event_path = root / "WoW" / "Source" / "Ui" / "Types.h"
    try:
        event_text = event_path.read_text(encoding="utf-8")
    except OSError:
        event_text = ""
    events = frozenset(_EVENT.findall(event_text)) | frozenset(_EVENT_ALIAS.findall(event_text))
    return {"functions": functions, "methods": methods, "events": events}


def known_events(root: Path | None = None) -> frozenset[str] | None:
    """The complete 12340 event table from the local decompilation, if available."""
    index = _load_decomp(root or DECOMP_DIR)
    return index["events"] or None


def _decomp_reference(name: str, root: Path | None = None) -> dict | None:
    index = _load_decomp(root or DECOMP_DIR)
    if ":" in name:
        widget, method = name.split(":", 1)
        entry = index["methods"].get(widget, {}).get(method)
        if entry:
            return {"source": "wowdecomp-12340", "symbol": entry["symbol"]}
        return None
    entry = index["functions"].get(name)
    if entry:
        return entry
    if name in index["events"]:
        return {"source": "wowdecomp-12340", "path": "WoW/Source/Ui/Types.h"}
    return None


def modern_global(name: str) -> str | None:
    if name in MODERN_GLOBALS:
        return MODERN_GLOBALS[name]
    if name in SANDBOX_MISSING:
        return SANDBOX_MISSING[name]
    if MODERN_PREFIX.match(name):
        return f"{name} is a C_ namespace; none exist in 3.3.5a"
    return None


def _fields(items, *keys) -> list[dict]:
    return [{k: item[k] for k in keys if k in item}
            for item in items or [] if isinstance(item, dict) and item.get("name")]


def _reference(entry: dict, signature: str | None = None) -> dict:
    # Signature, parameter and return names/types only: no protection flags
    # (wrong for 3.3.5a), no "optional" (false even for optional arguments)
    # and no prose (the data has no licence).
    ref = {"source": "milkyway-codex"}
    if signature or entry.get("signature"):
        ref["signature"] = (signature or entry["signature"]).split(" - ")[0].strip()
    ref["parameters"] = _fields(entry.get("parameters"), "name", "type")
    if "returns" in entry:
        ref["returns"] = _fields(entry.get("returns"), "name", "type")
    return ref


@lru_cache(maxsize=4)
def _load_codex(root: Path) -> dict[str, dict]:
    """name / EVENT / Widget:Method -> reference entry; empty when the data is absent or broken."""
    def read(name):
        try:
            data = json.loads((root / name).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return []
        return [d for d in data if isinstance(d, dict) and isinstance(d.get("name"), str)] \
            if isinstance(data, list) else []

    out: dict[str, dict] = {}
    for fn in read("api-functions.json"):
        out[fn["name"]] = {"kind": "function", **_reference(fn)}
    for ev in read("events.json"):
        out[ev["name"]] = {"kind": "event", "source": "milkyway-codex",
                           "payload": _fields(ev.get("parameters"), "name", "type")}
    widgets = {w["name"]: w for w in read("widgets.json")}
    for wname, widget in widgets.items():
        seen, chain = set(), [wname]
        while chain:  # own methods first, then inherited ones
            current = widgets.get(chain.pop(0))
            if not current or current["name"] in seen:
                continue
            seen.add(current["name"])
            for m in current.get("methods") or []:
                found = isinstance(m, dict) and re.search(r"\w+:(\w+)\(", str(m.get("name", "")))
                if found:
                    out.setdefault(f"{wname}:{found.group(1)}",
                                   {"kind": "method", **_reference(m, m.get("signature") or m["name"])})
            chain += [i for i in current.get("inherits") or [] if isinstance(i, str)]
    return out


def reference(name: str, root: Path | None = None) -> dict | None:
    """Signature or event payload for NAME from the local Codex data, if present."""
    return _load_codex(root or CODEX_DIR).get(name)


def lookup(name: str, path: Path | None = None, codex: Path | None = None,
           decomp: Path | None = None) -> dict:
    """Answer 'does this global (or Widget:Method, or event) exist on 3.3.5a?' for agents and humans."""
    result = _exists(name, path, codex, decomp)
    ref = reference(name, codex) if result["exists"] is not False else None
    if ref:
        result["reference"] = {k: v for k, v in ref.items() if k != "kind"}
    implementation = _decomp_reference(name, decomp)
    if implementation:
        result["implementation"] = implementation
    return result


def _exists(name: str, path: Path | None, codex: Path | None, decomp: Path | None) -> dict:
    index = _load_decomp(decomp or DECOMP_DIR)
    if ":" in name:
        widget, method = name.split(":", 1)
        methods = known_methods(path).get(widget)
        if method in MODERN_METHODS:
            return {"name": name, "exists": False, "source": "builtin", "hint": MODERN_METHODS[method]}
        if methods is not None:
            return {"name": name, "exists": method in methods, "source": "client-dump"}
        decomp_methods = index["methods"].get(widget)
        if decomp_methods is not None:
            return {"name": name, "exists": method in decomp_methods, "source": "wowdecomp-12340"}
        return {"name": name, "exists": None, "source": "unknown",
                "hint": "No method dump or decompiled type for this widget; run 'forge api dump'"}
    if name in MODERN_EVENTS:
        return {"name": name, "kind": "event", "exists": False, "source": "builtin",
                "hint": MODERN_EVENTS[name]}
    if name in index["events"]:
        return {"name": name, "kind": "event", "exists": True, "source": "wowdecomp-12340"}
    ref = reference(name, codex)
    if ref and ref["kind"] == "event":  # the dump holds globals, not the event table
        return {"name": name, "kind": "event", "exists": True, "source": "milkyway-codex",
                "hint": "Event list from the MilkyWay Codex, not the client; confirm live if it matters"}
    problem = modern_global(name)
    dump = known_globals(path)
    if problem:
        return {"name": name, "exists": False, "source": "builtin", "hint": problem}
    if dump is not None:
        return {"name": name, "exists": name in dump or name in LUA51_GLOBALS,
                "source": "client-dump"}
    if name in index["functions"]:
        return {"name": name, "exists": True, "source": "wowdecomp-12340"}
    if name in LUA51_GLOBALS:
        return {"name": name, "exists": True, "source": "builtin"}
    return {"name": name, "exists": None, "source": "unknown",
            "hint": "Not a native API in the local decompilation; run 'forge api dump' for FrameXML and runtime globals"}


ENTRY = re.compile(r"(?:[A-Za-z]{2,32}:)?[A-Za-z_][A-Za-z0-9_]{0,99}")


def write_dump(entries: list[str], path: Path | None = None) -> Path:
    path = path or DUMP_PATH
    clean = sorted({n for n in entries if isinstance(n, str) and ENTRY.fullmatch(n)})
    if sum(1 for n in clean if ":" not in n) < 1000:
        raise RuntimeError(f"Implausibly small global dump ({len(clean)} entries); not saved")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("# _G keys and Widget:Method names dumped from the isolated 3.3.5a (12340)\n"
                    "# test client by 'forge api dump'. Local data; do not upload.\n"
                    + "\n".join(clean) + "\n", encoding="utf-8")
    _load_dump.cache_clear()
    return path
