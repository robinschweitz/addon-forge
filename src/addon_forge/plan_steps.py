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


def _find_item_code(item_id: int) -> str:
    return ("for bag = 0, 4 do for slot = 1, GetContainerNumSlots(bag) do "
            "local link = GetContainerItemLink(bag, slot) "
            f"if link and string.match(link, 'item:(%d+)') == '{int(item_id)}' then "
            "return bag .. ':' .. slot end end end return 'missing'")


def _initiate_code(name: str) -> str:
    return ("for i = 1, 4 do if UnitName('party' .. i) == " + json.dumps(name) + " then "
            "InitiateTrade('party' .. i) return 'ok' end end return 'no_peer'")


TRADE_OPEN_CODE = "return (TradeFrame and TradeFrame:IsShown()) and 'ok' or 'closed'"


def _place_code(bag: int, slot: int, item_id: int) -> str:
    return (f"ClearCursor() PickupContainerItem({int(bag)}, {int(slot)}) ClickTradeButton(1) ClearCursor() "
            "local link = GetTradePlayerItemLink(1) "
            f"return (link and string.match(link, 'item:(%d+)') == '{int(item_id)}') and 'ok' or 'not_placed'")


def _trade_to_peer(item_id: int, peer, lua, sleep) -> str:
    """Trade one item from the graphical character's bags to the fixture bot.

    Order matters on the server: the bot must answer BEGIN_TRADE, both sides are
    unaccepted whenever an item lands, and the trade completes once both accept.
    """
    found = lua(_find_item_code(item_id))
    if not isinstance(found, str) or not re.fullmatch(r"\d:\d{1,2}", found):
        return f"item_not_in_bags:{found}"
    bag, slot = (int(x) for x in found.split(":"))
    opening = peer.send("open_trade")
    ready = peer.wait_armed(opening, timeout=10)
    if ready != "ok":
        return f"bot_not_listening:{ready}"
    started = lua(_initiate_code(peer.name))
    if started != "ok":
        return f"initiate:{started}"
    result = peer.wait(opening, timeout=20)
    if result != "ok":
        return f"bot_open:{result}"
    for _ in range(20):
        if lua(TRADE_OPEN_CODE) == "ok":
            break
        sleep(0.25)
    else:
        return "trade_window_not_shown"
    placed = lua(_place_code(bag, slot, item_id))
    if placed != "ok":
        return f"place:{placed}"
    sleep(1)  # let the server's unaccept (BACK_TO_TRADE) settle before accepting
    accepting = peer.send("accept_trade")
    sleep(0.5)
    if lua("AcceptTrade() return 'ok'") != "ok":
        return "client_accept_failed"
    result = peer.wait(accepting, timeout=25)
    return "ok" if result == "ok" else f"bot_accept:{result}"


def run_steps(steps: list[dict], pid: int, *, rpc=None, sleep=time.sleep, peer=None,
              screenshot=None) -> list[dict]:
    """Run steps in order; stop at the first one the client did not perform.

    `peer` is the master_loot fixture's bot (peer_roll, peer_trade); `screenshot`
    saves the client window under a name and returns the file path.
    """
    rpc = rpc or request  # resolved at call time so the transport can be replaced

    def lua(code: str):
        reply = rpc("lua.evaluate", {"code": code}, expected_pid=pid)
        return reply.get("result") if isinstance(reply, dict) and reply.get("ok") is True else "sdk_error"

    log = []
    for index, step in enumerate(steps, 1):
        kind, value = step["type"], step["value"]
        entry = {**step}
        if kind == "wait":
            sleep(value)
            result = "ok"
        elif kind == "screenshot":
            if screenshot is None:
                result = "no_screenshot_support"
            else:
                try:
                    entry["path"] = str(screenshot(value))
                    result = "ok"
                except (OSError, RuntimeError) as exc:
                    result = f"screenshot_failed:{type(exc).__name__}"
        elif kind in ("peer_roll", "peer_trade"):
            if peer is None:
                result = "no_fixture_peer"
            elif kind == "peer_roll":
                result = peer.roll(*value)
            else:
                result = _trade_to_peer(value, peer, lua, sleep)
        else:
            result = lua(_code(step))
        entry["result"] = result
        log.append(entry)
        if result != "ok":
            error = StepFailed(f"Step {index} {kind} {value!r} failed: {result}")
            error.log = log
            raise error
    return log
