"""Opt-in SDK client for a private, marked WoW test copy.

The WoWControlSDK is external and untrusted. Its JSON-RPC named pipe has
default Windows ACLs; use a dedicated Windows user with no untrusted local
processes. Never put passwords in launcher arguments, logs or files.
"""
from __future__ import annotations
import json
from pathlib import Path
import re
import subprocess
import sys
import time
from .config import Config

PIPE = r"\\.\pipe\WowGameCommand"
ERROR_MORE_DATA = 234
MAX_REPLY = 4 * 1024 * 1024
CHARACTER = re.compile(r"[A-Za-z]{2,12}\Z")
ALLOWED = frozenset({"client.ping", "client.getScreen", "client.getCharacters",
                      "client.login", "client.enterWorld", "unit.get",
                      "lua.evaluate"})


def require_windows_transport():
    """Fail before launching WoW if the named-pipe Python extension is missing."""
    if sys.platform != "win32":
        raise RuntimeError("WoWControlSDK requires native Windows")
    try:
        import win32file
        import pywintypes  # noqa: F401 - catches a broken pywin32 installation
    except (ImportError, OSError) as exc:
        raise RuntimeError(
            "WoWControlSDK requires pywin32 in this Forge virtual environment. "
            'Run .\\.venv\\Scripts\\python.exe -m pip install -e ".[windows]" '
            "from the Addon Forge checkout; close the separate test WoW, then retry. "
            "No SDK login should start until this check passes."
        ) from exc
    return win32file


def request(method: str, params: dict | None = None, *, expected_pid: int, transport=None) -> dict:
    if method not in ALLOWED:
        raise ValueError("Unapproved SDK method")
    if transport is None:
        transport = require_windows_transport()
    from .wowcontrol_pipe import open_verified_pipe
    handle = open_verified_pipe(transport, expected_pid)
    try:
        data = json.dumps({"jsonrpc":"2.0", "id":1, "method":method,
                           "params": params or {}}, separators=(",", ":")).encode()
        if len(data) > 2048:
            raise ValueError("SDK request too large")
        transport.WriteFile(handle, data)
        # The SDK pipe is message-mode: a reply larger than one read arrives in
        # pieces with ERROR_MORE_DATA until the whole message has been read.
        chunks, total = [], 0
        while True:
            status, chunk = transport.ReadFile(handle, 65536)
            chunks.append(chunk)
            total += len(chunk)
            if total > MAX_REPLY:
                raise RuntimeError("SDK reply exceeds the size limit")
            if status != ERROR_MORE_DATA:
                break
        reply = b"".join(chunks)
        try:
            parsed = json.loads(reply)
        except ValueError as exc:
            raise RuntimeError(f"SDK returned a truncated or malformed reply ({len(reply)} bytes)") from exc
        if parsed.get("id") != 1 or parsed.get("error"):
            raise RuntimeError("SDK returned a failed or mismatched reply")
        return parsed.get("result", {})
    finally:
        transport.CloseHandle(handle)


def wait_for_screen(call, expected: str, *, timeout: float = 65,
                    interval: float = 0.6, clock=None, sleep=None) -> dict:
    """Wait for WoW glue UI to initialize before sending any credentials.

    Pipe readiness only establishes that the injected DLL is serving RPCs,
    not that the WoW login/character-selection UI finished loading.
    """
    if expected not in ("login", "charselect"):
        raise ValueError("Only known pre-world states can be awaited")
    clock = clock or time.monotonic
    sleep = sleep or time.sleep
    deadline = clock() + timeout
    last = {"screen": "<not yet queried>"}
    stable = 0
    while True:
        last = call("client.getScreen")
        if not isinstance(last, dict):
            raise RuntimeError("WoWControlSDK returned an invalid screen state")
        screen = last.get("screen")
        if screen == expected and last.get("inWorld") is not True:
            stable += 1
            if stable >= 2:
                return last
        else:
            stable = 0
            if last.get("inWorld") is True or screen == "world":
                raise RuntimeError("WoWControlSDK reports an already in-world client; "
                                   "refusing automated account login or selection.")
            if expected == "login" and screen == "charselect":
                raise RuntimeError("WoWControlSDK reports character selection before login; "
                                   "refusing to reuse an unverified account/realm.")
        if clock() >= deadline:
            # Avoid printing SDK memory addresses, secrets or arbitrary payloads.
            label = screen if isinstance(screen, str) and screen in (
                "", "login", "charselect", "world") else "<unknown>"
            login_state = last.get("loginState")
            login_state = login_state if type(login_state) is int else "<unknown>"
            raise RuntimeError(
                f"WoWControlSDK screen never reached {expected!r}; "
                f"last screen={label!r}, loginState={login_state!r}. "
                "Check the isolated WoW window for startup/first-run dialogs. "
                "No credentials are sent when the login screen cannot be verified.")
        sleep(interval)


def wait_for_player_identity(call, character: str, *, timeout: float = 35,
                             interval: float = 0.7, clock=None, sleep=None,
                             mismatch_grace: float = 8.0) -> dict:
    """Require two stable matches after allowing transient world-entry SDK names.

    Do NOT call lua.evaluate("return UnitName('player')") here: on the pinned
    native SDK build it can terminate Wow.exe (observed 2026-10-14). This is
    only a preliminary SDK check; the bridge observer also needs an independent
    report. An SDK-only observer does not claim addon acceptance.
    """
    if not CHARACTER.fullmatch(character):
        raise ValueError("Invalid character name")
    clock = clock or time.monotonic
    sleep = sleep or time.sleep
    deadline = clock() + timeout
    stable = 0
    unit_state = "unavailable"
    first_world_at = None
    while True:
        screen = call("client.getScreen")
        if not isinstance(screen, dict):
            raise RuntimeError("SDK returned invalid world state")
        if screen.get("screen") == "world" or screen.get("inWorld") is True:
            if first_world_at is None:
                first_world_at = clock()
            unit = call("unit.get", {"token": "player"})
            if not isinstance(unit, dict):
                raise RuntimeError("SDK returned invalid player unit state")
            unit_name = unit.get("name")
            if unit.get("exists") is True and isinstance(unit_name, str) and unit_name:
                if unit_name.casefold() != character.casefold():
                    unit_state = "mismatched"
                    stable = 0
                    if clock() - first_world_at >= mismatch_grace:
                        raise RuntimeError("SDK unit API persistently reports a different player; refusing test.")
                else:
                    unit_state = "matched"
                    stable += 1
                    if stable >= 2:
                        return {"status": "sdk_unit_matched", "character": character}
            else:
                unit_state = "not_ready"
                stable = 0
        else:
            stable = 0
            unit_state = "not_in_world"
        if clock() >= deadline:
            raise RuntimeError(
                "SDK player identity did not become ready after world entry: "
                f"unit={unit_state}. "
                "No scenario was authorized.")
        sleep(interval)


def launch_and_enter(cfg: Config, character: str, *, rpc=request, press_idle=None,
                     role: str = "main") -> int:
    """Start an injected test client and enter the world with `character`.

    role "main" requires that no test client runs yet. role "member" starts a
    second client next to the running main one (a two-player plan) and logs in
    with the credentials of the "member" slot.
    """
    from . import clients
    from .win_login import _test_copy, _credentials
    from .windows_client import _client_binary, WindowsAPI
    if sys.platform != "win32":
        raise RuntimeError("Native Windows required")
    if not CHARACTER.fullmatch(character):
        raise ValueError("Invalid test character")
    if rpc is request:
        require_windows_transport()
    wow = _test_copy(cfg.wow_dir)
    if not cfg.wowcontrol_realm or not re.fullmatch(r"[A-Za-z0-9 _-]{2,64}", cfg.wowcontrol_realm):
        raise ValueError("Configure a specific local wowcontrol_realm before logging in")
    if not cfg.wowcontrol_injector or not cfg.wowcontrol_dll:
        raise ValueError("Configure both wowcontrol_injector and wowcontrol_dll")
    injector, dll = cfg.wowcontrol_injector, cfg.wowcontrol_dll
    if not injector.is_file() or not dll.is_file() or injector.is_symlink() or dll.is_symlink():
        raise RuntimeError("SDK injector and DLL must be regular local files")
    # The injector launches the *marked* test executable, never the original.
    # Do not use --kill, --pipe-cmd, or --wow-args (which could expose secrets).
    api = WindowsAPI()
    binary = _client_binary(wow)
    existing = {owner for _, owner in api.find_windows(cfg.window_name, binary)}
    if role == "main" and existing:
        raise RuntimeError("Close the existing test WoW before an SDK startup")
    if role == "member" and clients.pid_of("main") not in existing:
        raise RuntimeError("Start the main test client before the member client")
    # The Forge SDK build serves a per-process pipe the injector cannot name in
    # advance, so it waits a fixed time (the DLL needs ~0.1 s) before resuming.
    timing = ["--no-pipe", "--wait", "1500" if role == "main" else "3000"]
    subprocess.run([str(injector), "--wow", str(binary), "--dll", str(dll), *timing],
                   cwd=str(wow), check=True, timeout=60)
    until = time.monotonic() + 45
    pid = None
    while time.monotonic() < until:
        new = [owner for _, owner in api.find_windows(cfg.window_name, binary) if owner not in existing]
        if len(new) > 1:
            raise RuntimeError("More than one new test client window appeared")
        if new:
            pid = new[0]
            break
        time.sleep(0.4)
    if pid is None:
        raise RuntimeError("Instrumented test client did not create a verified window")
    clients.register(role, pid)
    account, password = _credentials(wow, role)
    def call(method, params=None):
        return rpc(method, params, expected_pid=pid)
    # A second client's SDK pipe needs a moment; until then only the main
    # client's pipe answers (and is rejected by its process ID).
    ping_until = time.monotonic() + (30 if role == "main" else 90)
    last_error = "no reply"
    while True:
        try:
            ready = call("client.ping").get("status") == "ok"
        except RuntimeError as exc:
            ready, last_error = False, str(exc)
        if ready:
            break
        if time.monotonic() >= ping_until:
            raise RuntimeError(f"SDK pipe unavailable (last: {last_error})")
        time.sleep(0.5)
    wait_for_screen(call, "login")
    if call("client.login", {"username":account, "password":password,
                            "realmName":cfg.wowcontrol_realm}).get("ok") is not True:
        raise RuntimeError("SDK local login failed")
    wait_for_screen(call, "charselect", timeout=15)
    characters = call("client.getCharacters").get("characters", [])
    if not any(isinstance(c, dict) and c.get("name") == character for c in characters):
        raise RuntimeError("Requested character is absent from realm")
    if call("client.enterWorld", {"name":character, "wait":True}).get("ok") is not True:
        raise RuntimeError("SDK world entry failed")
    # Identity first: no lua.evaluate is sent until unit.get confirms the
    # character, because Lua during world entry crashed the pinned SDK build.
    wait_for_player_identity(call, character)
    reset_idle_timer(call, press_idle or _idle_press(cfg, role))
    return pid


def _idle_press(cfg: Config, role: str = "main"):
    from .windows_client import WindowsClientController
    return WindowsClientController(cfg, role=role).press_idle_key


# WoW measures inactivity from the last real keyboard/mouse input. A client
# started through the SDK injector has none, so it is "idle" from login and
# starts an idle logout (CAMP dialog) that the SDK's IdleLogoutHook blocks,
# which repeats every few seconds and hides other dialogs such as invites.
# One harmless key press on an unbound chord resets that timer.
IDLE_KEY = "CTRL-SHIFT-F11"
IDLE_KEY_FREE_CODE = f"return GetBindingAction('{IDLE_KEY}') or ''"
# Locale-independent: the idle logout is the CAMP dialog; CancelLogout is not protected.
IDLE_POPUP_CODE = "if StaticPopup_Visible('CAMP') then CancelLogout() return 'dismissed' end return 'none'"


def reset_idle_timer(call, press, *, settle: float = 1.0, sleep=None) -> dict:
    """Reset the client's inactivity timer with one unbound key press, then
    cancel an idle-logout dialog that was already showing."""
    free = call("lua.evaluate", {"code": IDLE_KEY_FREE_CODE})
    if not isinstance(free, dict) or free.get("ok") is not True:
        raise RuntimeError("SDK could not read the idle-reset key binding")
    if free.get("result") not in ("", None):
        raise RuntimeError(f"{IDLE_KEY} is bound to {free.get('result')!r} in the test client; "
                           "unbind it so the idle reset cannot trigger an action. No key was pressed.")
    press()
    (sleep or time.sleep)(settle)
    reply = call("lua.evaluate", {"code": IDLE_POPUP_CODE})
    if not isinstance(reply, dict) or reply.get("ok") is not True:
        raise RuntimeError("SDK could not inspect the idle logout dialog")
    return {"idle_key": IDLE_KEY, "camp_cancelled": reply.get("result") == "dismissed"}

def client_pid(cfg: Config, role: str = "main") -> int:
    """PID of the verified, marked test client window (never another WoW);
    in a two-player plan, the client registered for `role`."""
    from . import clients
    from .windows_client import WindowsAPI, _client_binary
    from .win_login import _test_copy
    wow = _test_copy(cfg.wow_dir)
    api = WindowsAPI()
    return api.window_pid(api.find_window(cfg.window_name, _client_binary(wow), pid=clients.pid_of(role)))


WATCH_PATH = re.compile(r"[A-Za-z_][A-Za-z0-9_]{0,63}(?:\.[A-Za-z0-9_]{1,64}){0,5}")
BRIDGE_VERSION = 3


def bridge_run(cfg: Config, suite: str, run_id: str, paths: tuple[str, ...] = (), *,
               rpc=request, pid: int | None = None) -> dict:
    """Run a bridge suite and receive its JSON report in the same SDK call.

    Replaces the typed '/forge run' + '/reload' + SavedVariables round trip.
    The Lua is constant apart from validated identifiers and dotted paths.
    """
    if not suite.isalnum() or not run_id.isalnum() or len(run_id) > 32:
        raise ValueError("Suite and run id must be alphanumeric")
    if len(paths) > 10 or any(not WATCH_PATH.fullmatch(p) for p in paths):
        raise ValueError("Watch up to 10 dotted global paths such as MyAddonDB.count")
    pid = pid if pid is not None else client_pid(cfg)
    watched = "{" + ",".join(json.dumps(p) for p in paths) + "}"
    code = ("if type(ForgeTestBridge) ~= 'table' or type(ForgeTestBridge.RunJSON) ~= 'function' "
            "then return 'bridge_missing' end "
            f"return ForgeTestBridge:RunJSON({json.dumps(suite)}, {json.dumps(run_id)}, {watched})")
    reply = rpc("lua.evaluate", {"code": code}, expected_pid=pid)
    if not isinstance(reply, dict) or reply.get("ok") is not True:
        raise RuntimeError("SDK could not run the ForgeTestBridge suite")
    raw = reply.get("result")
    if raw == "bridge_missing":
        raise RuntimeError("ForgeTestBridge v3 is not loaded; deploy it and restart the test client")
    try:
        report = json.loads(raw) if isinstance(raw, str) else None
    except ValueError as exc:
        raise RuntimeError("ForgeTestBridge returned malformed JSON") from exc
    if not isinstance(report, dict):
        raise RuntimeError("ForgeTestBridge returned no report object")
    return report


# Constant, read-only apart from creating one hidden probe widget per type on the
# first call. Returns "total|last|entries" so large dumps arrive in chunks.
API_DUMP_CODE = (
    "local d = ForgeApiDump "
    "if not d then d = {} "
    "for k in pairs(_G) do if type(k) == 'string' then d[#d + 1] = k end end "
    "local function add(kind, obj) local mt = obj and getmetatable(obj) local idx = mt and mt.__index "
    "if type(idx) == 'table' then for m in pairs(idx) do if type(m) == 'string' then d[#d + 1] = kind .. ':' .. m end end end end "
    "for _, kind in ipairs({'Frame','Button','CheckButton','EditBox','Slider','StatusBar','ScrollFrame',"
    "'MessageFrame','ScrollingMessageFrame','GameTooltip','Cooldown','Model','PlayerModel','ColorSelect','SimpleHTML'}) do "
    "local ok, f = pcall(CreateFrame, kind) if ok and f then add(kind, f) f:Hide() end end "
    "add('FontString', UIParent:CreateFontString()) add('Texture', UIParent:CreateTexture()) add('Font', GameFontNormal) "
    "table.sort(d) ForgeApiDump = d end "
    "local i, out, size = START, {}, 0 "
    "while d[i] and size < 20000 do out[#out + 1] = d[i] size = size + #d[i] + 1 i = i + 1 end "
    "return #d .. '|' .. (i - 1) .. '|' .. table.concat(out, ',')")


def dump_api(cfg: Config, *, rpc=request, pid: int | None = None) -> dict:
    """Dump _G keys and widget methods from the in-world test client to wow/api."""
    from . import wowapi
    pid = pid if pid is not None else client_pid(cfg)
    screen = rpc("client.getScreen", expected_pid=pid)
    if not isinstance(screen, dict) or not (screen.get("inWorld") is True or screen.get("screen") == "world"):
        raise RuntimeError("Enter the world with the test character before dumping the API")
    entries: list[str] = []
    start = 1
    for _ in range(400):
        reply = rpc("lua.evaluate", {"code": API_DUMP_CODE.replace("START", str(start))}, expected_pid=pid)
        raw = reply.get("result") if isinstance(reply, dict) and reply.get("ok") is True else None
        parts = raw.split("|", 2) if isinstance(raw, str) else []
        if len(parts) != 3 or not parts[0].isdigit() or not parts[1].isdigit():
            raise RuntimeError("Unexpected API dump reply from the SDK")
        total, last = int(parts[0]), int(parts[1])
        entries += [e for e in parts[2].split(",") if e]
        if last >= total:
            break
        if last < start:
            raise RuntimeError("API dump made no progress")
        start = last + 1
    else:
        raise RuntimeError("API dump did not finish")
    entries = [e for e in entries if e != "ForgeApiDump"]
    path = wowapi.write_dump(entries)
    return {"status": "dumped", "path": str(path),
            "globals": sum(1 for e in entries if ":" not in e),
            "methods": sum(1 for e in entries if ":" in e),
            "note": "Includes globals of addons loaded at dump time; dump with only ForgeTestBridge enabled for a clean list."}


def bridge_command(cfg: Config, command: str) -> None:
    """Call only the installed Forge bridge slash handler, not arbitrary Lua."""
    from .windows_client import validate_chat_command
    validate_chat_command(command)
    if not command.startswith("/forge "):
        raise ValueError("Only Forge bridge commands use SDK Lua transport")
    pid = client_pid(cfg)
    argument = json.dumps(command[len("/forge "):], ensure_ascii=True)
    code = ("if type(SlashCmdList) ~= 'table' or "
            "type(SlashCmdList.FORGETEST) ~= 'function' then "
            "return 'bridge_missing' end "
            "SlashCmdList.FORGETEST(" + argument + ") return 'ok'")
    result = request("lua.evaluate", {"code": code}, expected_pid=pid)
    if result.get("ok") is not True or result.get("result") != "ok":
        raise RuntimeError("SDK did not execute the installed Forge bridge handler")


def client_status(cfg: Config, *, inspect_player: bool = False, rpc=request) -> dict:
    """Read-only diagnostics for an already injected, marked graphical client.

    Never invokes injector, login, input, process termination or deploy.\n    Optional --player performs only a constant read-only Lua query.
    """
    from .windows_client import WindowsAPI, _client_binary
    from .win_login import _test_copy
    wow = _test_copy(cfg.wow_dir)
    api = WindowsAPI()
    hwnd = api.find_window(cfg.window_name, _client_binary(wow))
    pid = api.window_pid(hwnd)
    response = rpc("client.getScreen", expected_pid=pid)
    if not isinstance(response, dict):
        raise RuntimeError("Unexpected WoWControlSDK screen response")
    raw_screen = response.get("screen")
    screen = raw_screen if raw_screen in ("login", "charselect", "world", "") else "<unknown>"
    state = response.get("loginState")
    result = {"status": "observed", "backend": "wowcontrol", "pid": pid,
              "screen": screen, "in_world": response.get("inWorld") is True,
              "login_state": state if type(state) is int else None,
              "note": "PID-verified read-only state; no credentials or mutations sent"}
    if inspect_player and result["in_world"]:
        # Avoid SDK lua.evaluate(UnitName): a native crash was reproduced.
        unit = rpc("unit.get", {"token": "player"}, expected_pid=pid)
        if not isinstance(unit, dict):
            raise RuntimeError("Invalid SDK player diagnostic response")
        unit_name = unit.get("name")
        result["player"] = {
            "unit_exists": unit.get("exists") is True,
            "unit_name": unit_name if isinstance(unit_name, str) and
                         CHARACTER.fullmatch(unit_name) else None,
            "verification": "sdk_only; fresh ForgeTestBridge v2 report required",
        }
    return result
