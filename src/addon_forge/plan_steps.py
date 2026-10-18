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
    if kind == "paste":
        name, text = value
        return ("local f = ForgeTestBridge and ForgeTestBridge.frames and ForgeTestBridge.frames["
                + json.dumps(name) + "] "
                "if not f then return 'missing' end if not f:IsVisible() then return 'hidden' end "
                "if not f.IsObjectType or not f:IsObjectType('EditBox') then return 'not_an_editbox' end "
                "f:SetFocus() f:SetText(" + json.dumps(text) + ") f:ClearFocus() return 'ok'")
    raise ValueError(f"No SDK action for step {kind!r}")


# hardware_click: SDK Lua (f:Click()) is no hardware event, so functions such as
# CalendarAddEvent refuse it (ADDON_ACTION_BLOCKED). The step binds one fixed,
# otherwise unused chord to CLICK <Frame>:LeftButton, presses it with SendInput
# and restores the previous binding. Binding clicks look the frame up by its
# global name, so the registered frame must carry that name.
CLICK_KEY = "CTRL-SHIFT-F10"
PREVIOUS_BINDING = re.compile(r"[A-Za-z0-9_: -]{0,80}")


def _bind_click_code(name: str) -> str:
    n = json.dumps(name)
    return ("local name, key = " + n + ", '" + CLICK_KEY + "' "
            "local b = ForgeTestBridge local f = b and b.frames and b.frames[name] "
            "if not f then return 'missing' end if not f:IsVisible() then return 'hidden' end "
            "if type(f.Click) ~= 'function' then return 'not_clickable' end "
            "if f:GetName() ~= name or _G[name] ~= f then return 'no_global_name' end "
            "b.hardwareClicks = b.hardwareClicks or {} "
            "if not b.hardwareClicks[name] then b.hardwareClicks[name] = 0 "
            "f:HookScript('OnClick', function() b.hardwareClicks[name] = b.hardwareClicks[name] + 1 end) end "
            "local prev = GetBindingAction(key) or '' "
            "SetBindingClick(key, name, 'LeftButton') "
            "if GetBindingAction(key) ~= 'CLICK ' .. name .. ':LeftButton' then return 'bind_failed' end "
            "return 'bound:' .. b.hardwareClicks[name] .. ':' .. prev")


def _click_count_code(name: str) -> str:
    return "return ForgeTestBridge.hardwareClicks[" + json.dumps(name) + "]"


def _restore_click_code(previous: str) -> str:
    if previous:
        return f"SetBinding('{CLICK_KEY}', {json.dumps(previous)}) return 'ok'"
    return f"SetBinding('{CLICK_KEY}') return 'ok'"


def _hardware_click(name: str, lua, press, sleep, timeout: float = 3) -> str:
    bound = lua(_bind_click_code(name))
    if not isinstance(bound, str) or not bound.startswith("bound:"):
        return bound if isinstance(bound, str) else "sdk_error"
    _, count, previous = bound.split(":", 2)
    if not PREVIOUS_BINDING.fullmatch(previous):
        lua(_restore_click_code(""))
        return "unexpected_previous_binding"
    before = float(count)
    try:
        press()
        # The key arrives through the window's message queue; wait for OnClick.
        for _ in range(int(timeout / 0.25)):
            sleep(0.25)
            now = lua(_click_count_code(name))
            if isinstance(now, (int, float)) and not isinstance(now, bool) and now > before:
                return "ok"
        return "not_clicked"
    finally:
        lua(_restore_click_code(previous))


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
              screenshot=None, pids: dict | None = None, press_click=None) -> list[dict]:
    """Run steps in order; stop at the first one the client did not perform.

    `peer` is the master_loot fixture's bot (peer_roll, peer_trade); `screenshot`
    saves a client window under a name and returns the file path; `press_click`
    sends the hardware_click chord to a client's window. In a
    two-player plan `pids` maps "member" to the second client's process, and a
    step with "client": "member" runs there.
    """
    rpc = rpc or request  # resolved at call time so the transport can be replaced
    pids = {"main": pid, **(pids or {})}
    current = {"pid": pid}

    def lua(code: str):
        reply = rpc("lua.evaluate", {"code": code}, expected_pid=current["pid"])
        return reply.get("result") if isinstance(reply, dict) and reply.get("ok") is True else "sdk_error"

    log = []
    for index, step in enumerate(steps, 1):
        kind, value = step["type"], step["value"]
        client = step.get("client", "main")
        if client not in pids:
            error = StepFailed(f"Step {index} {kind} needs the {client} client, which is not running")
            error.log = log
            raise error
        current["pid"] = pids[client]
        entry = {**step}
        if kind == "wait":
            sleep(value)
            result = "ok"
        elif kind == "screenshot":
            if screenshot is None:
                result = "no_screenshot_support"
            else:
                try:
                    entry["path"] = str(screenshot(value) if client == "main" else screenshot(value, client))
                    result = "ok"
                except (OSError, RuntimeError) as exc:
                    result = f"screenshot_failed:{type(exc).__name__}"
        elif kind == "hardware_click":
            if press_click is None:
                result = "no_hardware_input"
            else:
                press = (lambda: press_click()) if client == "main" else (lambda: press_click(client))
                try:
                    result = _hardware_click(value, lua, press, sleep)
                except (OSError, RuntimeError) as exc:
                    result = f"key_press_failed:{exc}"
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
