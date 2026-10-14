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
        _, reply = transport.ReadFile(handle, 32768)
        parsed = json.loads(reply)
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


def launch_and_enter(cfg: Config, character: str, *, rpc=request) -> int:
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
    try:
        api.find_window(cfg.window_name, _client_binary(wow))
    except RuntimeError as exc:
        if "found 0." not in str(exc):
            raise
    else:
        raise RuntimeError("Close the existing test WoW before an SDK startup")
    subprocess.run([str(injector), "--wow", str(_client_binary(wow)), "--dll", str(dll)],
                   cwd=str(wow), check=True, timeout=60)
    until = time.monotonic() + 45
    hwnd = None
    while time.monotonic() < until:
        try:
            hwnd = api.find_window(cfg.window_name, _client_binary(wow))
            break
        except RuntimeError as exc:
            if "found 0." not in str(exc):
                raise
        time.sleep(0.4)
    if hwnd is None:
        raise RuntimeError("Instrumented test client did not create a verified window")
    pid = api.window_pid(hwnd)
    account, password = _credentials(wow)
    def call(method, params=None):
        return rpc(method, params, expected_pid=pid)
    if call("client.ping").get("status") != "ok":
        raise RuntimeError("SDK pipe unavailable")
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
    wait_for_player_identity(call, character)
    return pid

def bridge_command(cfg: Config, command: str) -> None:
    """Call only the installed Forge bridge slash handler, not arbitrary Lua."""
    from .windows_client import WindowsAPI, _client_binary, validate_chat_command
    from .win_login import _test_copy
    validate_chat_command(command)
    if not command.startswith("/forge "):
        raise ValueError("Only Forge bridge commands use SDK Lua transport")
    wow = _test_copy(cfg.wow_dir)
    api = WindowsAPI()
    hwnd = api.find_window(cfg.window_name, _client_binary(wow))
    pid = api.window_pid(hwnd)
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
