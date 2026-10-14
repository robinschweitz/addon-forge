"""Strict, independent acceptance contracts for agent-created addons."""
from __future__ import annotations

import json
from pathlib import Path
import re

NAME = re.compile(r"[a-zA-Z][a-zA-Z0-9_]{0,39}\Z")
CHARACTER = re.compile(r"[A-Za-z]{2,12}\Z")
ALLOWED_SUITE = {"smoke", "peer"}
ALLOWED_TYPE = {"frame_visible", "target_player", "player_in_world", "party_count_at_least"}


def validate_plan(data: dict) -> dict:
    if not isinstance(data, dict) or not {"version", "addon", "character", "peers", "checks"}.issubset(data) or set(data) - {"version", "addon", "character", "peers", "checks", "observer"}:
        raise ValueError("Plan needs version, addon, character, peers and checks, with no extra keys")
    if data["version"] != 1 or not NAME.fullmatch(str(data["addon"])):
        raise ValueError("Expected version 1 and a simple addon name")
    if not CHARACTER.fullmatch(str(data["character"])):
        raise ValueError("Expected the already-in-world graphical test character name")
    observer = data.get("observer", "bridge")
    if observer not in ("bridge", "sdk"):
        raise ValueError("observer must be bridge or sdk")
    peers = data["peers"]
    if type(peers) is not int or not 0 <= peers <= 4:
        raise ValueError("peers must be 0-4")
    checks = data["checks"]
    if not isinstance(checks, list) or not 1 <= len(checks) <= 20:
        raise ValueError("Provide 1-20 independent checks")
    clean = []
    seen = set()
    for item in checks:
        if not isinstance(item, dict) or set(item) != {"type", "value"}:
            raise ValueError("Each check requires exactly type and value")
        kind, value = item["type"], item["value"]
        if kind not in ALLOWED_TYPE:
            raise ValueError(f"Unsupported independent check {kind!r}")
        if kind == "frame_visible":
            if not isinstance(value, str) or not NAME.fullmatch(value):
                raise ValueError("Invalid frame name")
        elif kind in ("target_player", "player_in_world"):
            if value is not True:
                raise ValueError(f"{kind} requires true")
            if kind == "target_player" and peers == 0:
                raise ValueError("target_player requires at least one peer")
        elif type(value) is not int or not 0 <= value <= 4:
            raise ValueError("party_count_at_least requires integer 0-4")
        key = (kind, str(value))
        if key in seen:
            raise ValueError("Duplicate check")
        seen.add(key)
        clean.append({"type": kind, "value": value})
    if observer == "sdk" and (peers or any(chk["type"] != "player_in_world" for chk in clean)):
        raise ValueError("SDK-only observer currently supports only player_in_world with peers=0; UI/addon checks require the bridge")
    result = {"version": 1, "addon": data["addon"], "character": data["character"],
              "peers": peers, "checks": clean}
    if "observer" in data:
        result["observer"] = observer
    return result


def load_plan(path: Path) -> dict:
    if path.suffix.lower() != ".json" or not path.is_file():
        raise ValueError("Scenario must be an existing JSON file")
    if path.stat().st_size > 20_000:
        raise ValueError("Scenario is too large")
    return validate_plan(json.loads(path.read_text(encoding="utf-8")))


def evaluate(plan: dict, report: dict) -> dict:
    """Validate independent telemetry; no success from addon assertions alone."""
    if not report.get("completed") or not isinstance(report.get("snapshot"), dict):
        return {"status": "infrastructure_error", "checks": [], "error": "No bridge telemetry"}
    state = report["snapshot"]
    results = []
    for chk in plan["checks"]:
        kind, val = chk["type"], chk["value"]
        if kind == "frame_visible":
            frame = state.get("frames", {}).get(val)
            actual = frame.get("shown") if isinstance(frame, dict) else None
            passed = actual is True
        elif kind == "target_player":
            actual = state.get("target", {}).get("isPlayer")
            passed = actual is True
        elif kind == "player_in_world":
            actual = state.get("player", {}).get("exists")
            passed = actual is True
        else:
            actual = state.get("party", {}).get("count")
            passed = type(actual) is int and actual >= val
        results.append({"type": kind, "expected": val, "actual": actual, "passed": passed})
    return {"status": "passed" if all(x["passed"] for x in results) else "failed",
            "checks": results}
