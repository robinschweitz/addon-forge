"""Safe idempotent preparation of the marked WoW test client.

Prepares only the existing isolated test copy. Never alters Docker containers,
accounts or character selection. Login goes through the WoWControlSDK only;
credentials are never typed.
"""
from __future__ import annotations

from pathlib import Path
import sys

from .config import Config
from .deploy import deploy

BRIDGE_VERSION = 3


def prepare_environment(cfg: Config, *, start_client: bool = False,
                        login: bool = False, enter_character: str | None = None,
                        observer: str = "bridge") -> dict:
    if observer not in ("bridge", "sdk"):
        raise ValueError("Unknown observer")
    if observer == "sdk" and cfg.automation_backend != "wowcontrol":
        raise ValueError("SDK-only observer requires wowcontrol backend")
    if enter_character and (not login or not start_client):
        raise ValueError("--enter-character requires both --login and --start-client")
    if login and not start_client:
        raise ValueError("--login requires --start-client")
    if login and (cfg.automation_backend != "wowcontrol" or not enter_character):
        raise ValueError("Automated login uses the WoWControlSDK only: set automation_backend = "
                         "\"wowcontrol\" and pass both --login and --enter-character")
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
    if observer == "bridge" and not bridge.is_dir():
        raise RuntimeError("Matching ForgeTestBridge source not found")
    # Deploying a changed bridge cannot reload it in a running WoW process.
    # Fail before copying so the user can restart cleanly, not get stale data.
    if running:
        return {
            "status": "client_running",
            "bridge_deployed": False,
            "client_started": False,
            "next": "Use the current in-world client if bridge v3 is already loaded; "
                    "otherwise close the test client and rerun prepare.",
        }
    if login:
        from .wowcontrol import require_windows_transport
        require_windows_transport()  # No addon deployment or injection on missing pywin32.
    installed = deploy(bridge, wow) if observer == "bridge" else None
    if not start_client:
        return {"status": "prepared", "bridge_deployed": observer == "bridge",
                "path": str(installed) if installed else None, "client_started": False}
    if login:
        from .wowcontrol import launch_and_enter
        pid = launch_and_enter(cfg, enter_character)
        if observer == "sdk":
            return {"status": "sdk_character_observed", "backend": "wowcontrol",
                    "pid": pid, "bridge_deployed": False, "client_started": True,
                    "verification": "SDK unit only; no independent addon telemetry"}
        from .runner import run_smoke
        # Identity only: errors from other enabled addons must not block login.
        report = run_smoke(cfg, suite="smoke", required_tests=("bridge_loaded",),
                           out_dir=Path(".forge-runs"), owner="ForgeTestBridge")
        bridge_report = report.details.get("report", {})
        snapshot = bridge_report.get("snapshot", {})
        player = snapshot.get("player", {}) if isinstance(snapshot, dict) else {}
        name = player.get("name") if isinstance(player, dict) else None
        reason = None
        if report.status != "passed":
            reason = f"bridge smoke {report.status}: {report.details.get('error') or report.details.get('errors')}"
        elif bridge_report.get("bridgeVersion") != BRIDGE_VERSION or bridge_report.get("schemaVersion") != BRIDGE_VERSION:
            reason = f"bridge v{bridge_report.get('bridgeVersion')} loaded, v{BRIDGE_VERSION} required"
        elif not isinstance(name, str) or name.casefold() != enter_character.casefold():
            reason = f"in-world player is {name!r}, expected {enter_character!r}"
        if reason:
            raise RuntimeError(f"SDK login did not independently verify the character in ForgeTestBridge: {reason}")
        result = {"status": "character_verified", "backend": "wowcontrol", "pid": pid,
                  "bridge_deployed": True, "client_started": True, "run_id": report.run_id}
        if report.details.get("foreign_errors"):
            result["other_addon_errors"] = report.details["foreign_errors"]
        return result
    pid = ClientController(cfg).start()
    return {"status": "client_started", "bridge_deployed": True,
            "client_started": True, "pid": pid,
            "next": "World character identity is verified only when status is "
                    "character_verified. Otherwise run an in-world correlated test."}
