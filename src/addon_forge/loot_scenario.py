"""Bounded real server master-loot fixture for the isolated test realm.

Used by acceptance plans that list ``"fixtures": ["master_loot"]``.
"""
from contextlib import contextmanager
import json
import re
import subprocess
import tempfile
import time
from pathlib import Path

from .agent_realm import _preflight
from .peer_scenario import _fixture_env
from .windows_client import WindowsAPI, _client_binary, WindowsClientController
from .win_login import _test_copy
from .wowcontrol import CHARACTER, request, reset_idle_timer

# TargetUnit/InteractUnit are protected in 3.3.5 and the creature name is
# localized, so success is only claimed once the real loot window has items.
LOOT_OPEN_CODE = "return (LootFrame and LootFrame:IsShown() and GetNumLootItems()) or 0"
# LeaveParty is not protected. Scripting the chat edit box instead (the old
# workaround) left ChatFrame1EditBox broken and raised an error every frame.
LEAVE_PARTY_CODE = "if GetNumPartyMembers() > 0 or GetNumRaidMembers() > 0 then LeaveParty() end return true"


def _corpse_names(state: dict, fallback: str = "Crimson Templar") -> list[str]:
    """Validated corpse names from the fixture (localized first)."""
    names = state.get("names")
    clean = [n for n in names if isinstance(n, str) and 0 < len(n) <= 64
             and not any(ord(c) < 32 or c in '"\\' for c in n)] if isinstance(names, list) else []
    return list(dict.fromkeys(clean)) or [fallback]


def _target_code(name: str) -> str:
    # json.dumps(ensure_ascii=False) yields a valid Lua string for names without
    # quotes, backslashes or control characters (validated above).
    return (f"TargetUnit({json.dumps(name, ensure_ascii=False)}) "
            "return (UnitExists('target') and UnitIsDead('target')) and 1 or 0")


INTERACT_KEY = "CTRL-SHIFT-F12"
BIND_CODE = (f"local prev = GetBindingAction('{INTERACT_KEY}') or '' "
             f"SetBinding('{INTERACT_KEY}', 'INTERACTTARGET') return prev")


def _restore_code(previous: str) -> str:
    if previous:
        return f"SetBinding('{INTERACT_KEY}', {json.dumps(previous)}) return true"
    return f"SetBinding('{INTERACT_KEY}') return true"


def _open_corpse(names: list[str], pid: int, *, rpc=request, press_key=None,
                 loot_timeout: float = 5) -> tuple[str | None, int]:
    """Target the corpse by each candidate name, then open its loot. Returns (name, items).

    Lua InteractUnit is tried first; it needs a hardware event, so the fallback
    temporarily binds one fixed chord to INTERACTTARGET, presses it once in the
    verified WoW window and restores the previous binding.
    """
    targeted = None
    for name in names:
        reply = rpc("lua.evaluate", {"code": _target_code(name)}, expected_pid=pid)
        if reply.get("ok") is True and reply.get("result") == 1:
            targeted = name
            break
    if targeted is None:
        raise RuntimeError(f"Could not target the fixture corpse by any of {names} "
                           "(TargetUnit blocked as protected, wrong localized name, or out of range)")
    # Lua numbers arrive from the SDK as JSON floats (1.0), not ints.
    opened = lambda n: isinstance(n, (int, float)) and not isinstance(n, bool) and n > 0
    rpc("lua.evaluate", {"code": "InteractUnit('target') return true"}, expected_pid=pid)
    items = _poll_lua(LOOT_OPEN_CODE, pid, opened, timeout=min(loot_timeout, 2), rpc=rpc)
    if opened(items):
        return targeted, int(items)
    if press_key is None:
        raise RuntimeError(f"Targeted corpse {targeted!r}, but InteractUnit did not open loot "
                           "and no interact key fallback is available")
    bound = rpc("lua.evaluate", {"code": BIND_CODE}, expected_pid=pid)
    previous = bound.get("result") if bound.get("ok") is True else None
    if not isinstance(previous, str) or not re.fullmatch(r"[A-Za-z0-9_: -]{0,64}", previous):
        raise RuntimeError("Could not bind the temporary interact key; nothing was pressed")
    try:
        press_key()
        items = _poll_lua(LOOT_OPEN_CODE, pid, opened, timeout=loot_timeout, rpc=rpc)
    finally:
        rpc("lua.evaluate", {"code": _restore_code(previous)}, expected_pid=pid)
    if not opened(items):
        raise RuntimeError(f"Targeted corpse {targeted!r}, but neither InteractUnit nor the "
                           f"{INTERACT_KEY} interact key opened loot (out of range or corpse not lootable)")
    return targeted, int(items)


# The invite can land in any StaticPopup slot (the idle-logout dialog often holds
# slot 1), and PARTY_INVITE declines itself when hidden unaccepted, so find it by
# its dialog type instead of assuming StaticPopup1.
FIND_INVITE_CODE = "return StaticPopup_Visible('PARTY_INVITE') or ''"
VISIBLE_POPUPS_CODE = ("local t = {} for i = 1, 4 do local f = _G['StaticPopup' .. i] "
                       "if f and f:IsShown() then t[#t + 1] = tostring(f.which) end end "
                       "return table.concat(t, ',')")
POPUP_NAME = re.compile(r"StaticPopup[1-4]")


def _accept_invite(pid: int, *, rpc=request, screenshot=None, timeout: float = 10):
    """Accept the fixture's party invite in whichever popup slot holds it."""
    name = _poll_lua(FIND_INVITE_CODE, pid, lambda n: isinstance(n, str) and bool(POPUP_NAME.fullmatch(n)),
                     timeout=timeout, rpc=rpc)
    if not isinstance(name, str) or not POPUP_NAME.fullmatch(name):
        shown = rpc("lua.evaluate", {"code": VISIBLE_POPUPS_CODE}, expected_pid=pid).get("result")
        raise RuntimeError(f"Group invite popup did not appear (visible popups: {shown or 'none'})")
    image = screenshot() if screenshot else None
    clicked = rpc("lua.evaluate", {"code": f"local b = _G['{name}Button1'] "
                                           "if b and b:IsShown() then b:Click() return true end return false"},
                  expected_pid=pid)
    if clicked.get("ok") is not True or clicked.get("result") is not True:
        raise RuntimeError(f"Could not click accept on the group invite in {name}")
    return image


def _leave_party(pid: int, *, rpc=request) -> None:
    """Best-effort cleanup so no fixture bot stays in the GUI character's party."""
    try:
        rpc("lua.evaluate", {"code": LEAVE_PARTY_CODE}, expected_pid=pid)
    except (OSError, RuntimeError, ValueError):
        pass


def _read_state(path: Path) -> dict | None:
    """Return the fixture handshake, or None while it is absent or mid-write."""
    try:
        if path.is_symlink() or path.stat().st_size > 4096:
            raise RuntimeError("Untrusted or oversized loot fixture state")
        state = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, ValueError, UnicodeError):
        return None
    return state if isinstance(state, dict) else None


def _wait_for_status(path: Path, status: str, proc, *, timeout: float, clock=time.monotonic,
                     sleep=time.sleep) -> dict:
    deadline = clock() + timeout
    while True:
        state = _read_state(path)
        if state is not None and state.get("status") == status:
            return state
        if proc.poll() is not None:
            raise RuntimeError(f"Loot fixture exited before reporting {status!r}")
        if clock() >= deadline:
            seen = state.get("status") if state else None
            raise RuntimeError(f"Loot fixture did not report {status!r} within {timeout:.0f}s "
                               f"(last status={seen!r})")
        sleep(0.2)


def _poll_lua(code: str, pid: int, accept, *, timeout: float, rpc=request):
    """Poll a constant Lua expression until ``accept(result)``; return the last result."""
    until = time.monotonic() + timeout
    result = None
    while True:
        reply = rpc("lua.evaluate", {"code": code}, expected_pid=pid)
        result = reply.get("result") if reply.get("ok") is True else None
        if accept(result) or time.monotonic() >= until:
            return result
        time.sleep(0.2)


class FixturePeer:
    """The fixture's party bot, driven through numbered command files.

    The Go fixture executes ``cmd-NNN.json`` in order and answers with
    ``cmd-NNN.done.json``; actions are fixed (roll, open_trade, accept_trade).
    """

    ACTIONS = {"roll", "open_trade", "accept_trade"}

    def __init__(self, folder: Path, proc, name: str, *, clock=time.monotonic, sleep=time.sleep):
        if not CHARACTER.fullmatch(name or ""):
            raise RuntimeError("Loot fixture reported an invalid bot name")
        self.folder, self.proc, self.name = folder, proc, name
        self.count = 0
        self._clock, self._sleep = clock, sleep

    def send(self, action: str, **args) -> int:
        if action not in self.ACTIONS:
            raise ValueError(f"Unknown peer action {action!r}")
        self.count += 1
        path = self.folder / f"cmd-{self.count:03d}.json"
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps({"action": action, **args}), encoding="utf-8")
        tmp.replace(path)
        return self.count

    def wait(self, number: int, timeout: float) -> str:
        done = self.folder / f"cmd-{number:03d}.done.json"
        deadline = self._clock() + timeout
        while True:
            state = _read_state(done)
            if state is not None:
                result = state.get("result")
                return result if isinstance(result, str) else "bad_result"
            if self.proc.poll() is not None:
                return "fixture_exited"
            if self._clock() >= deadline:
                return "timeout"
            self._sleep(0.1)

    def wait_armed(self, number: int, timeout: float) -> str:
        """Wait until the bot listens for the command's server responses."""
        armed = self.folder / f"cmd-{number:03d}.armed"
        deadline = self._clock() + timeout
        while not armed.exists():
            if (self.folder / f"cmd-{number:03d}.done.json").exists():
                return "finished_early"
            if self.proc.poll() is not None:
                return "fixture_exited"
            if self._clock() >= deadline:
                return "timeout"
            self._sleep(0.05)
        return "ok"

    def roll(self, low: int, high: int) -> str:
        return self.wait(self.send("roll", min=int(low), max=int(high)), timeout=10)


def _stop(proc, release: Path) -> None:
    release.touch()
    try:
        proc.wait(timeout=25)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=10)


PLAN = {"fixture": "master_loot", "changes": [
    "Creates one temporary AzerothGhost bot and a temporary party with the graphical test character",
    "Revives the graphical test character (and the member character) first if they are dead",
    "Spawns, kills and cleans up the fixed Crimson Templar loot fixture",
    "Designates the graphical character as master looter for Abyssal Crest (item 20513)",
    "Keeps the real master-loot window open while the plan's bridge suite runs",
    "Lets peer_roll / peer_trade plan steps make the bot /rnd or accept a trade"],
    "limitations": ["Uses SDK game-thread Lua for invite acceptance",
                    "Targets the corpse by its client-locale name (from the world DB) with protected "
                    "TargetUnit; opens loot with InteractUnit or, failing that, one press of a "
                    "temporarily bound CTRL-SHIFT-F12 interact key (previous binding restored)",
                    "Does not automate a player vote or award"]}

# The boe_loot option: a stock creature whose loot table always drops a
# bind-on-equip item. Unchanged world data; the Go fixture confirms the drop
# with a fixed read-only query before spawning.
BOE_PLAN_CHANGES = [
    "Spawns, kills and cleans up The Rake (creature 5807) instead of the Crimson Templar",
    "Designates the graphical character as master looter for Lionfur Armor (item 17922, "
    "uncommon, binds when equipped; stock 100% drop)"]
BOE_LIMITATIONS = ["The Rake's stock world-loot reference may add a random extra item "
                   "(rarely uncommon or better) beside Lionfur Armor"]


def fixture_plan(*, boe: bool = False) -> dict:
    """What the fixture changes, for the plan preview and the result."""
    if not boe:
        return PLAN
    changes = [c for c in PLAN["changes"] if "Crimson Templar" not in c and "Abyssal Crest" not in c]
    return {**PLAN, "changes": changes[:1] + BOE_PLAN_CHANGES + changes[1:],
            "limitations": PLAN["limitations"] + BOE_LIMITATIONS}


@contextmanager
def master_loot_fixture(cfg, *, character: str, output: Path, member: str | None = None, lead: bool = False,
                        boe: bool = False):
    """Hold a real master-loot window open on the graphical client for the duration."""
    if not CHARACTER.fullmatch(character):
        raise ValueError("Invalid test character")
    if not cfg.realm_dir:
        raise RuntimeError("Set [realm] source_dir in forge.local.toml")
    wow = _test_copy(cfg.wow_dir)
    api = WindowsAPI()
    hwnd = api.find_window(cfg.window_name, _client_binary(wow))
    pid = api.window_pid(hwnd)
    output.mkdir(parents=True, exist_ok=True)
    realm = cfg.realm_dir.resolve()
    password, port = _preflight(realm)
    member_pid = None
    if member:
        from . import clients
        if not CHARACTER.fullmatch(member) or member == character:
            raise ValueError("Invalid member character")
        member_pid = clients.pid_of("member")
        if not member_pid:
            raise RuntimeError("The member client is not running")
        request("lua.evaluate", {"code": LEAVE_PARTY_CODE}, expected_pid=member_pid)
    left = request("lua.evaluate", {"code": LEAVE_PARTY_CODE}, expected_pid=pid)
    if left.get("ok") is not True:
        raise RuntimeError("SDK could not submit stale-party cleanup")
    time.sleep(1)
    members = request("lua.evaluate", {"code": "return GetNumPartyMembers()"}, expected_pid=pid)
    if members.get("ok") is not True or members.get("result") != 0:
        raise RuntimeError("Graphical test character is still in a party before fixture start")
    locale = request("lua.evaluate", {"code": "return GetLocale()"}, expected_pid=pid).get("result")
    # Without real input the SDK client cycles idle-logout dialogs, which can
    # hide (and so auto-decline) the fixture's party invite.
    reset_idle_timer(lambda method, params=None: request(method, params, expected_pid=pid),
                     WindowsClientController(cfg).press_idle_key)
    with tempfile.TemporaryDirectory(prefix="forge-loot-") as temp:
        folder = Path(temp)
        ready, release = folder / "ready.json", folder / "release"
        env = _fixture_env(password, port, character, folder)
        env.update({"FORGE_LOOT_READY": str(ready), "FORGE_LOOT_RELEASE": str(release),
                    "FORGE_LOOT_COMMANDS": str(folder),
                    "FORGE_MEMBER_CHARACTER": member or "",
                    "FORGE_LEAD_TO_TARGET": "1" if lead else "",
                    "FORGE_LOOT_BOE": "1" if boe else "",
                    "FORGE_CLIENT_LOCALE": locale if isinstance(locale, str) and locale.isalpha() else "enUS"})
        with (output / "loot-fixture.log").open("wb+") as log:
            proc = subprocess.Popen(["go", "test", "-tags=e2e", "-run", "^TestLootRollFixture$", "-count=1", "-v", "-timeout", "420s", "-p", "1", "-parallel", "1"], cwd=Path(__file__).resolve().parents[2] / "agent_scenarios", env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                try:
                    invited = _wait_for_status(ready, "invite_sent", proc, timeout=55)
                    invite_image = _accept_invite(pid, screenshot=lambda: WindowsClientController(cfg).screenshot(
                        output / "loot-invite.png"))
                    if member_pid:
                        _wait_for_status(ready, "member_invite_sent", proc, timeout=55)
                        _accept_invite(member_pid, screenshot=lambda: WindowsClientController(cfg, role="member")
                                       .screenshot(output / "loot-invite-member.png"))
                    state = _wait_for_status(ready, "master_loot_ready", proc, timeout=80)
                    try:
                        corpse, items = _open_corpse(
                            _corpse_names(state, "The Rake" if boe else "Crimson Templar"), pid,
                            press_key=WindowsClientController(cfg).press_interact_key)
                    finally:
                        image = WindowsClientController(cfg).screenshot(output / "loot-open.png")
                except Exception as exc:
                    log.flush()
                    log.seek(0)
                    tail = log.read()[-4000:].decode("utf-8", "replace")
                    raise RuntimeError(str(exc) + "\nFixture log:\n" + tail) from exc
                yield {**fixture_plan(boe=boe), "item": state.get("item"), "corpse_name": corpse, "loot_items": items,
                       "screenshot": str(image), "invite_screenshot": str(invite_image),
                       "peer": FixturePeer(folder, proc, invited.get("bot"))}
            finally:
                _stop(proc, release)
                _leave_party(pid)
                if member_pid:
                    _leave_party(member_pid)
