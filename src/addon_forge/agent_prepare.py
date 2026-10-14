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
                        login: bool = False, enter_character: str | None = None) -> dict:
    if enter_character and (not login or not start_client):
        raise ValueError("--enter-character requires both --login and --start-client")
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
    if enter_character:
        from .win_character import read_character_calibration
        read_character_calibration(wow, enter_character)
    if login:
        from .win_login import start_and_login
        pid = start_and_login(cfg, api=api)
        status = "login_submitted"
        if enter_character:
            from .win_character import enter_character as perform_entry
            perform_entry(cfg, enter_character, pid=pid, api=api)
            from .runner import run_smoke
            report = run_smoke(cfg, suite="smoke",
                               required_tests=("bridge_loaded",),
                               out_dir=Path(".forge-runs"))
            snapshot = report.details.get("report", {}).get("snapshot", {})
            observed_name = snapshot.get("player", {}).get("name") if isinstance(snapshot, dict) else None
            bridge = report.details.get("report", {})
            if (report.status != "passed" or bridge.get("bridgeVersion") != 2
                    or bridge.get("schemaVersion") != 2
                    or not isinstance(observed_name, str)
                    or observed_name.casefold() != enter_character.casefold()):
                raise RuntimeError("World entry could not verify character identity "
                                   "using a fresh ForgeTestBridge v2 report; "
                                   "no automated scenario should continue.")
            status = "character_verified"
    else:
        pid = ClientController(cfg).start()
        status = "client_started"
    return {"status": status, "bridge_deployed": True,
            "client_started": True, "pid": pid,
            "next": "World character identity is verified only when status is "
                    "character_verified. Otherwise run an in-world correlated test."}
