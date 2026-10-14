"""Safe idempotent preparation of the marked WoW test client.

Prepares only the existing isolated test copy. Never alters Docker containers,
accounts or character selection, and never types uncalibrated credentials.
"""
from __future__ import annotations

from pathlib import Path
import sys

from .config import Config
from .deploy import deploy


def prepare_environment(cfg: Config, *, start_client: bool = False,
                        login: bool = False) -> dict:
    if login and not start_client:
        raise ValueError("--login requires --start-client")
    if sys.platform != "win32":
        raise RuntimeError("Automated preparation is currently Windows-only.")
    from .windows_client import WindowsAPI, _client_binary
    from .win_login import _test_copy
    from .client import ClientController

    wow = _test_copy(cfg.wow_dir)
    binary = _client_binary(wow)
    api = WindowsAPI()
    try:
        api.find_window(cfg.window_name, binary)
    except RuntimeError as exc:
        if "found 0." not in str(exc):
            raise
        running = False
    else:
        running = True

    root = Path(__file__).resolve().parents[2]
    bridge = root / "wow" / "ForgeTestBridge"
    if not bridge.is_dir():
        raise RuntimeError("Matching ForgeTestBridge source not found")
    # Deploying a changed bridge cannot reload it in a running WoW process.
    # Fail before copying so the user can restart cleanly, not get stale data.
    if running:
        return {
            "status": "client_running",
            "bridge_deployed": False,
            "client_started": False,
            "next": "Use the current in-world client if bridge v2 is already loaded; "
                    "otherwise close the test client and rerun prepare.",
        }
    installed = deploy(bridge, wow)
    if not start_client:
        return {"status": "prepared", "bridge_deployed": True,
                "path": str(installed), "client_started": False}
    if login:
        from .win_login import start_and_login
        pid = start_and_login(cfg, api=api)
        status = "login_submitted"
    else:
        pid = ClientController(cfg).start()
        status = "client_started"
    return {"status": status, "bridge_deployed": True,
            "client_started": True, "pid": pid,
            "next": "The graphical test character still needs to enter the world; "
                    "the in-client test command independently verifies it."}
