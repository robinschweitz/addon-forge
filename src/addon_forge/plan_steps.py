"""Execute a plan's validated steps in the real client over the SDK.

Every step type maps to one fixed Lua template filled only with values that
scenario_plan already validated (slash command shape, integers, frame names).
"""
from __future__ import annotations

import json
from pathlib import Path
import re
import time

from .wowcontrol import request

SLASH_DEF = re.compile(r"""SLASH_[A-Za-z0-9_]+\s*=\s*["'](/[^"'\s]+)["']""")


class StepFailed(RuntimeError):
    pass


def addon_slash_commands(addon_dir: Path) -> set[str]:
    """Slash commands the addon itself defines (steps may only run these)."""
    found = set()
    for lua in addon_dir.rglob("*.lua"):
        if "tests" in lua.relative_to(addon_dir).parts:
            continue
        found |= {m.lower() for m in SLASH_DEF.findall(lua.read_text(encoding="utf-8", errors="replace"))}
    return found


def _code(step: dict) -> str:
    kind, value = step["type"], step["value"]
    if kind == "slash":
        command, _, rest = value.partition(" ")
        return ("local cmd, rest = " + json.dumps(command.lower()) + ", " + json.dumps(rest) + " "
                "for key, fn in pairs(SlashCmdList) do local i = 1 "
                "while _G['SLASH_' .. key .. i] do "
                "if string.lower(_G['SLASH_' .. key .. i]) == cmd then fn(rest) return 'ok' end "
                "i = i + 1 end end return 'missing'")
    if kind == "roll":
        low, high = value
        return f"RandomRoll({int(low)}, {int(high)}) return 'ok'"
    if kind == "click":
        return ("local f = ForgeTestBridge and ForgeTestBridge.frames and ForgeTestBridge.frames["
                + json.dumps(value) + "] "
                "if not f then return 'missing' end if not f:IsVisible() then return 'hidden' end "
                "if type(f.Click) ~= 'function' then return 'not_clickable' end f:Click() return 'ok'")
    raise ValueError(f"No SDK action for step {kind!r}")


def run_steps(steps: list[dict], pid: int, *, rpc=None, sleep=time.sleep) -> list[dict]:
    """Run steps in order; stop at the first one the client did not perform."""
    rpc = rpc or request  # resolved at call time so the transport can be replaced
    log = []
    for index, step in enumerate(steps, 1):
        if step["type"] == "wait":
            sleep(step["value"])
            log.append({**step, "result": "ok"})
            continue
        reply = rpc("lua.evaluate", {"code": _code(step)}, expected_pid=pid)
        result = reply.get("result") if isinstance(reply, dict) and reply.get("ok") is True else "sdk_error"
        log.append({**step, "result": result})
        if result != "ok":
            raise StepFailed(f"Step {index} {step['type']} {step['value']!r} failed: {result}")
    return log
