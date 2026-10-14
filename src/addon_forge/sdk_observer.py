"""Bounded SDK-only observation path. Does not call lua.evaluate or ForgeTestBridge.

SDK-only evidence confirms the character is in the world, NOT addon behavior.
UI acceptance still requires a working in-game inspection backend.
"""
from .wowcontrol import request, wait_for_player_identity
from .windows_client import WindowsAPI, _client_binary
from .win_login import _test_copy


def run_sdk_observations(cfg, plan, *, rpc=request) -> dict:
    if plan.get("observer") != "sdk" or plan["peers"] or any(
        check["type"] != "player_in_world" for check in plan["checks"]
    ):
        raise ValueError("SDK-only mode cannot assess addon/UI checks")
    wow = _test_copy(cfg.wow_dir)
    api = WindowsAPI()
    hwnd = api.find_window(cfg.window_name, _client_binary(wow))
    pid = api.window_pid(hwnd)
    if not isinstance(pid, int) or pid <= 0:
        raise RuntimeError("No verified WoW process ID")
    def call(method, params=None):
        return rpc(method, params, expected_pid=pid)
    verified = wait_for_player_identity(call, plan["character"])
    checks = [{"type": "player_in_world", "expected": True,
               "actual": True, "passed": True}]
    return {"status": "observed", "backend": "wowcontrol", "pid": pid,
            "observation": verified, "checks": checks,
            "addon_verified": False,
            "note": "SDK-only world observation; addon functionality NOT verified"}
