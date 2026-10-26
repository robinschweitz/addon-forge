"""Strict, independent acceptance contracts for agent-created addons.

A plan is data only. Every check is judged from the bridge's independent
snapshot (frames, units, chat, events, watched globals, captured Lua errors),
never from the addon's own assertions alone.
"""
from __future__ import annotations

import json
from pathlib import Path
import re

NAME = re.compile(r"[a-zA-Z][a-zA-Z0-9_]{0,39}\Z")
CHARACTER = re.compile(r"[A-Za-z]{2,12}\Z")
EVENT = re.compile(r"[A-Z][A-Z0-9_]{2,63}\Z")
PATH = re.compile(r"[A-Za-z_][A-Za-z0-9_]{0,63}(?:\.[A-Za-z0-9_]{1,64}){0,5}\Z")
ALLOWED_SUITE = {"smoke", "peer"}
# raid_lead extends master_loot: the fixture bot then hands party leadership
# to the plan's character, like a real raid lead who invites and sorts groups.
# boe_loot extends master_loot too: the corpse is a stock creature that always
# drops a bind-on-equip item (Lionfur Armor) instead of the Abyssal Crest.
FIXTURES = {"master_loot", "raid_lead", "boe_loot"}
EXTENDS_MASTER_LOOT = ("raid_lead", "boe_loot")

# type -> exact key set (besides "type")
CHECK_KEYS = {
    "frame_visible": {"value"},
    "target_player": {"value"},
    "player_in_world": {"value"},
    "party_count_at_least": {"value"},
    "frame_text_contains": {"frame", "value"},
    "global_equals": {"path", "value"},
    "chat_contains": {"value"},
    "event_fired": {"value"},
    "no_lua_errors": {"value"},
}
ALLOWED_TYPE = set(CHECK_KEYS)
SDK_TYPES = {"player_in_world"}
TOP_KEYS = {"version", "addon", "character", "peers", "checks", "observer", "fixtures", "steps", "companions",
            "member", "member_addons"}
# A two-player plan names a second test character ("member", logged in on a
# second client with the member credentials). Steps and checks then take an
# optional "client": "member" to act on / observe that client.
CLIENTS = ("main", "member")
# Companions are sibling addons a scenario needs too (e.g. a raid lead's ledger
# for a members' wishlist addon): checked, deployed, and their slash commands
# usable in steps. At most this many.
MAX_COMPANIONS = 3

# Steps act in the real client between fixtures and the bridge suite. They are
# data, not code: each type maps to one fixed, validated SDK action.
SLASH = re.compile(r"/[a-z][a-z0-9]{1,19}(?: [A-Za-z0-9 _-]{1,60})?\Z")
MAX_STEPS, MAX_WAIT_TOTAL = 20, 180
PEER_STEPS = {"peer_roll", "peer_trade", "peer_say"}
# peer_say text is spoken by a GM bot (SC-014, T-026): it starts with a letter,
# so it is never a GM (. !) or slash command, and holds no '|' escape.
SAY_TEXT = re.compile(r"[A-Za-z][A-Za-z0-9 ,.:!?'-]{0,59}\Z")


def _step(item: dict) -> dict:
    if not isinstance(item, dict) or set(item) != {"type", "value"}:
        raise ValueError("Each step requires exactly type and value")
    kind, value = item["type"], item["value"]
    if kind == "slash":
        if not isinstance(value, str) or not SLASH.fullmatch(value):
            raise ValueError("slash step: one addon slash command such as '/myaddon start'")
    elif kind in ("roll", "peer_roll"):
        if (not isinstance(value, list) or len(value) != 2 or any(type(v) is not int for v in value)
                or not 1 <= value[0] <= value[1] <= 10000):
            raise ValueError(f"{kind} step value must be [low, high] with 1 <= low <= high <= 10000")
    elif kind == "peer_trade":
        if type(value) is not int or not 1 <= value <= 999999:
            raise ValueError("peer_trade step value must be the item ID to trade to the fixture's bot")
    elif kind == "peer_say":
        if (not isinstance(value, list) or not 1 <= len(value) <= 2 or not isinstance(value[0], str)
                or not SAY_TEXT.fullmatch(value[0])
                or len(value) == 2 and (type(value[1]) is not int or not 1 <= value[1] <= 999999)):
            raise ValueError("peer_say step value must be [\"text\"] or [\"text\", itemID]; the text is "
                             "1-60 characters, starts with a letter and holds only letters, digits, spaces "
                             "and , . : ! ? ' -")
    elif kind == "paste":
        if (not isinstance(value, list) or len(value) != 2 or not isinstance(value[0], str)
                or not NAME.fullmatch(value[0]) or not isinstance(value[1], str)):
            raise ValueError("paste step value must be [\"RegisteredEditBox\", \"text\"]")
        text = value[1]
        if not 1 <= len(text) <= 1000 or "|" in text or any(
                not (32 <= ord(c) < 127 or c == "\n") for c in text):
            raise ValueError("paste text must be 1-1000 printable ASCII characters or newlines, without '|'")
    elif kind == "screenshot":
        if not isinstance(value, str) or not NAME.fullmatch(value):
            raise ValueError("screenshot step value must be a short name such as 'roll_log'")
    elif kind == "wait":
        if not isinstance(value, (int, float)) or isinstance(value, bool) or not 0 < value <= 60:
            raise ValueError("wait step value must be seconds in (0, 60]")
    elif kind in ("click", "hardware_click"):
        if not isinstance(value, str) or not NAME.fullmatch(value):
            raise ValueError(f"{kind} step value must be a frame name registered with ForgeTestBridge")
    else:
        raise ValueError(f"Unsupported step {kind!r}; use slash, roll, wait, click, hardware_click, paste, "
                         "screenshot, peer_roll, peer_trade or peer_say")
    return {"type": kind, "value": value}


def slash_commands(plan: dict) -> set[str]:
    return {s["value"].split(" ", 1)[0] for s in plan.get("steps", []) if s["type"] == "slash"}


def _text(value, what, limit=120):
    if not isinstance(value, str) or not value or len(value) > limit or any(ord(c) < 32 for c in value):
        raise ValueError(f"{what} must be a non-empty single-line string up to {limit} characters")


def _check(item: dict, peers: int) -> dict:
    if not isinstance(item, dict) or "type" not in item:
        raise ValueError("Each check needs a type")
    kind = item["type"]
    if kind not in CHECK_KEYS:
        raise ValueError(f"Unsupported independent check {kind!r}")
    if set(item) != CHECK_KEYS[kind] | {"type"}:
        raise ValueError(f"{kind} requires exactly the keys {sorted(CHECK_KEYS[kind] | {'type'})}")
    value = item["value"]
    if kind == "frame_visible":
        if not isinstance(value, str) or not NAME.fullmatch(value):
            raise ValueError("Invalid frame name")
    elif kind in ("target_player", "player_in_world", "no_lua_errors"):
        if value is not True:
            raise ValueError(f"{kind} requires true")
        if kind == "target_player" and peers == 0:
            raise ValueError("target_player requires at least one peer")
    elif kind == "party_count_at_least":
        if type(value) is not int or not 0 <= value <= 4:
            raise ValueError("party_count_at_least requires integer 0-4")
    elif kind == "frame_text_contains":
        if not isinstance(item["frame"], str) or not NAME.fullmatch(item["frame"]):
            raise ValueError("Invalid frame name")
        _text(value, "frame_text_contains value")
    elif kind == "global_equals":
        if not isinstance(item["path"], str) or not PATH.fullmatch(item["path"]):
            raise ValueError("global_equals path must be a dotted global path such as MyAddonDB.history.1.item")
        if not (value is None or isinstance(value, (bool, int, float)) or isinstance(value, str) and len(value) <= 120):
            raise ValueError("global_equals value must be a string, number, boolean or null")
    elif kind == "chat_contains":
        _text(value, "chat_contains value")
    elif kind == "event_fired":
        if not isinstance(value, str) or not EVENT.fullmatch(value):
            raise ValueError("event_fired value must be an event name such as LOOT_OPENED")
    return {k: item[k] for k in ["type", *sorted(CHECK_KEYS[kind])]}


def validate_plan(data: dict) -> dict:
    if not isinstance(data, dict) or not {"version", "addon", "character", "peers", "checks"}.issubset(data) or set(data) - TOP_KEYS:
        raise ValueError(f"Plan needs version, addon, character, peers and checks; optional observer and fixtures; no other keys")
    if data["version"] != 1 or not NAME.fullmatch(str(data["addon"])):
        raise ValueError("Expected version 1 and a simple addon name")
    if not CHARACTER.fullmatch(str(data["character"])):
        raise ValueError("Expected the graphical test character name")
    observer = data.get("observer", "bridge")
    if observer not in ("bridge", "sdk"):
        raise ValueError("observer must be bridge or sdk")
    peers = data["peers"]
    if type(peers) is not int or not 0 <= peers <= 4:
        raise ValueError("peers must be 0-4")
    fixtures = data.get("fixtures", [])
    if not isinstance(fixtures, list) or len(set(fixtures)) != len(fixtures) or any(f not in FIXTURES for f in fixtures):
        raise ValueError(f"fixtures must be a list drawn from {sorted(FIXTURES)}")
    if fixtures and (peers or observer != "bridge"):
        raise ValueError("Fixtures run with the bridge observer and peers=0")
    for extension in EXTENDS_MASTER_LOOT:
        if extension in fixtures and "master_loot" not in fixtures:
            raise ValueError(f"{extension} extends the master_loot fixture; list both")
    steps = data.get("steps", [])
    if not isinstance(steps, list) or len(steps) > MAX_STEPS:
        raise ValueError(f"steps must be a list of at most {MAX_STEPS} steps")
    member = data.get("member")
    if member is not None and (not isinstance(member, str) or not CHARACTER.fullmatch(member)
                               or member == data["character"]):
        raise ValueError("member must be a second test character name, different from character")
    if member and (observer != "bridge" or peers):
        raise ValueError("Two-player plans run with the bridge observer and peers=0")
    # Which of the plan's addons the member's character loads (a raid member
    # runs the wishlist, not the raid lead's ledger). Absent: all of them.
    member_addons = data.get("member_addons")
    if member_addons is not None:
        allowed = {data["addon"], *data.get("companions", [])}
        if (not member or not isinstance(member_addons, list) or not 1 <= len(member_addons) <= 4
                or len(set(member_addons)) != len(member_addons)
                or any(not isinstance(a, str) or a not in allowed for a in member_addons)):
            raise ValueError("member_addons must list 1-4 of the plan's addon and companions, "
                             "and needs a member")
    parsed = []
    for raw in steps:
        item, client = _split_client(raw, member, "Step")
        step = _step(item)
        if client == "member":
            if step["type"] in PEER_STEPS:
                raise ValueError("peer_roll, peer_trade and peer_say act for the main client only")
            step["client"] = "member"
        parsed.append(step)
    steps = parsed
    if sum(s["value"] for s in steps if s["type"] == "wait") > MAX_WAIT_TOTAL:
        raise ValueError(f"steps may wait at most {MAX_WAIT_TOTAL} seconds in total")
    if steps and observer != "bridge":
        raise ValueError("Steps run with the bridge observer")
    if any(s["type"] in PEER_STEPS for s in steps) and "master_loot" not in fixtures:
        raise ValueError("peer_roll, peer_trade and peer_say steps drive the master_loot fixture's bot; "
                         "add \"fixtures\": [\"master_loot\"]")
    companions = data.get("companions", [])
    if (not isinstance(companions, list) or len(companions) > MAX_COMPANIONS
            or len(set(companions)) != len(companions)
            or any(not isinstance(c, str) or not NAME.fullmatch(c) or c == data["addon"] for c in companions)):
        raise ValueError(f"companions must be up to {MAX_COMPANIONS} other addon folder names beside the plan")
    if companions and observer != "bridge":
        raise ValueError("Companion addons run with the bridge observer")
    checks = data["checks"]
    if not isinstance(checks, list) or not 1 <= len(checks) <= 20:
        raise ValueError("Provide 1-20 independent checks")
    clean, seen = [], set()
    for raw in checks:
        item, client = _split_client(raw, member, "Check")
        chk = _check(item, peers)
        if client == "member":
            chk["client"] = "member"
        key = json.dumps(chk, sort_keys=True)
        if key in seen:
            raise ValueError("Duplicate check")
        seen.add(key)
        clean.append(chk)
    if any(len(watch_paths({"checks": clean}, client)) > 10 for client in CLIENTS):
        raise ValueError("At most 10 global_equals paths per plan and client")
    if observer == "sdk" and (peers or any(chk["type"] not in SDK_TYPES for chk in clean)):
        raise ValueError("SDK-only observer currently supports only player_in_world with peers=0; UI/addon checks require the bridge")
    result = {"version": 1, "addon": data["addon"], "character": data["character"],
              "peers": peers, "checks": clean}
    if "observer" in data:
        result["observer"] = observer
    if fixtures:
        result["fixtures"] = list(fixtures)
    if steps:
        result["steps"] = steps
    if companions:
        result["companions"] = list(companions)
    if member:
        result["member"] = member
    if member_addons:
        result["member_addons"] = list(member_addons)
    return result


def watch_paths(plan: dict, client: str = "main") -> tuple[str, ...]:
    return tuple(dict.fromkeys(c["path"] for c in plan["checks"]
                               if c["type"] == "global_equals" and c.get("client", "main") == client))


def _split_client(item, member, what):
    """Remove and validate an item's optional "client" key."""
    if not isinstance(item, dict):
        return item, "main"
    item = dict(item)
    client = item.pop("client", "main")
    if client not in CLIENTS:
        raise ValueError(f"{what} client must be one of {CLIENTS}")
    if client == "member" and not member:
        raise ValueError(f'{what} for the member client need a plan "member" character')
    return item, client


def load_plan(path: Path) -> dict:
    if path.suffix.lower() != ".json" or not path.is_file():
        raise ValueError("Scenario must be an existing JSON file")
    if path.stat().st_size > 20_000:
        raise ValueError("Scenario is too large")
    return validate_plan(json.loads(path.read_text(encoding="utf-8")))


def _list(value):
    return value if isinstance(value, list) else []


ADDON_IN_ERROR = re.compile(r"AddOns[\\/]+([^\\/:]+)[\\/]", re.IGNORECASE)


def split_errors(errors, owner) -> tuple[list, list]:
    """Split captured Lua errors into (owned, foreign).

    The test client may have other addons enabled; an error that names a
    different addon's file does not judge `owner` (one name, or several: the
    plan's addon and its companions). Errors without a file path stay owned, so
    unattributable failures still fail closed.
    """
    owners = {o.lower() for o in ((owner,) if isinstance(owner, str) else (owner or ()))}
    owned, foreign = [], []
    for error in _list(errors):
        match = ADDON_IN_ERROR.search(error) if isinstance(error, str) else None
        if owners and match and match.group(1).lower() not in owners | {"forgetestbridge"}:
            foreign.append(error)
        else:
            owned.append(error)
    return owned, foreign


def evaluate(plan: dict, report: dict, client: str = "main") -> dict:
    """Validate independent telemetry; no success from addon assertions alone.

    Only the checks for `client` are judged, against that client's report."""
    if not report.get("completed") or not isinstance(report.get("snapshot"), dict):
        return {"status": "infrastructure_error", "checks": [], "error": "No bridge telemetry"}
    state = report["snapshot"]
    frames = state.get("frames") if isinstance(state.get("frames"), dict) else {}
    results = []
    for chk in plan["checks"]:
        if chk.get("client", "main") != client:
            continue
        kind, val = chk["type"], chk["value"]
        if kind == "frame_visible":
            frame = frames.get(val)
            actual = frame.get("shown") if isinstance(frame, dict) else None
            passed = actual is True
        elif kind == "frame_text_contains":
            frame = frames.get(chk["frame"])
            actual = frame.get("text") if isinstance(frame, dict) else None
            passed = isinstance(actual, str) and val in actual
        elif kind == "target_player":
            actual = state.get("target", {}).get("isPlayer")
            passed = actual is True
        elif kind == "player_in_world":
            actual = state.get("player", {}).get("exists")
            passed = actual is True
        elif kind == "global_equals":
            values = state.get("values") if isinstance(state.get("values"), dict) else {}
            actual = values.get(chk["path"])
            present = chk["path"] in values
            if val is None:
                passed = actual is None  # Lua drops nil table values, so absent means nil.
            elif isinstance(val, (int, float)) and not isinstance(val, bool):
                passed = (present and isinstance(actual, (int, float))
                          and not isinstance(actual, bool) and actual == val)
            else:
                passed = present and type(actual) is type(val) and actual == val
        elif kind == "chat_contains":
            chat = _list(state.get("chat"))
            actual = next((line for line in chat if isinstance(line, str) and val in line), None)
            passed = actual is not None
        elif kind == "event_fired":
            events = state.get("events") if isinstance(state.get("events"), dict) else {}
            actual = events.get(val, 0)
            passed = type(actual) is int and actual > 0
        elif kind == "no_lua_errors":
            actual = split_errors(report.get("errors"), (plan["addon"], *plan.get("companions", ())))[0]
            passed = not actual
        else:
            actual = state.get("party", {}).get("count")
            passed = type(actual) is int and actual >= val
        result = {"type": kind, "expected": val, "actual": actual, "passed": passed}
        if "frame" in chk:
            result["frame"] = chk["frame"]
        if "path" in chk:
            result["path"] = chk["path"]
        if client != "main":
            result["client"] = client
        results.append(result)
    return {"status": "passed" if all(x["passed"] for x in results) else "failed",
            "checks": results}
