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


def request(method: str, params: dict | None = None, *, transport=None) -> dict:
    if method not in ALLOWED:
        raise ValueError("Unapproved SDK method")
    if transport is None:
        if sys.platform != "win32":
            raise RuntimeError("WoWControlSDK requires Windows")
        import win32file
        transport = win32file
    from .wowcontrol_pipe import open_verified_pipe
    handle = open_verified_pipe(transport)
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


def launch_and_enter(cfg: Config, character: str, *, rpc=request) -> int:
    from .win_login import _test_copy, _credentials
    from .windows_client import _client_binary, WindowsAPI
    if sys.platform != "win32":
        raise RuntimeError("Native Windows required")
    if not CHARACTER.fullmatch(character):
        raise ValueError("Invalid test character")
    wow = _test_copy(cfg.wow_dir)
    if not cfg.wowcontrol_injector or not cfg.wowcontrol_dll:
        raise ValueError("Configure both wowcontrol_injector and wowcontrol_dll")
    injector, dll = cfg.wowcontrol_injector, cfg.wowcontrol_dll
    if not injector.is_file() or not dll.is_file() or injector.is_symlink() or dll.is_symlink():
        raise RuntimeError("SDK injector and DLL must be regular local files")
    # The injector launches the *marked* test executable, never the original.
    # Do not use --kill, --pipe-cmd, or --wow-args (which could expose secrets).
    subprocess.run([str(injector), "--wow", str(_client_binary(wow)), "--dll", str(dll)],
                   cwd=str(wow), check=True, timeout=60)
    api = WindowsAPI()
    hwnd = api.find_window(cfg.window_name, _client_binary(wow))
    pid = api.window_pid(hwnd)
    account, password = _credentials(wow)
    if rpc("client.ping").get("status") != "ok":
        raise RuntimeError("SDK pipe unavailable")
    if rpc("client.getScreen").get("screen") != "login":
        raise RuntimeError("SDK client not on login screen")
    if rpc("client.login", {"username":account, "password":password,
                            "realmName":cfg.wowcontrol_realm}).get("ok") is not True:
        raise RuntimeError("SDK local login failed")
    if rpc("client.getScreen").get("screen") != "charselect":
        raise RuntimeError("Expected character selection after login")
    characters = rpc("client.getCharacters").get("characters", [])
    if not any(isinstance(c, dict) and c.get("name") == character for c in characters):
        raise RuntimeError("Requested character is absent from realm")
    if rpc("client.enterWorld", {"name":character, "wait":True}).get("ok") is not True:
        raise RuntimeError("SDK world entry failed")
    identity = rpc("lua.evaluate", {"code":"return UnitName('player')"})
    if identity.get("ok") is not True or identity.get("result") != character:
        raise RuntimeError("SDK Lua player identity disagrees")
    return pid
