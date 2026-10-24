"""Windows approved QA session runner."""
from pathlib import Path
from .config import Config
from .scenario_plan import load_plan

def run_session(cfg: Config, plan_path: Path, *, approve: bool = False):
    plan = load_plan(plan_path)
    observer = plan.get("observer", "bridge")
    if observer == "sdk" and cfg.automation_backend != "wowcontrol":
        raise ValueError("SDK observer requires wowcontrol backend")
    if not approve:
        return {"status": "plan_only", "plan": plan}
    from .win_login import _test_copy, _credentials
    from . import windows_client
    from .windows_client import _client_binary
    from .deploy import deploy
    from .agent_prepare import prepare_environment
    from .agent_workflow import run_plan
    from .validate import check_addon, is_valid
    import sys
    if sys.platform != "win32":
        raise RuntimeError("Native Windows is required")
    wow = _test_copy(cfg.wow_dir)
    # A test client left over from an earlier session would keep its old code:
    # close it (only the marked copy's processes) before deploying (FR-7.6).
    closed = windows_client.close_test_clients(windows_client.WindowsAPI(), cfg.window_name, _client_binary(wow))

    addon = (plan_path.resolve().parent / plan["addon"]).resolve()
    if not addon.is_relative_to(plan_path.resolve().parent) or not addon.is_dir():
        raise ValueError("Scenario addon must exist alongside plan")
    companions = [(plan_path.resolve().parent / name).resolve() for name in plan.get("companions", [])]
    if any(not c.is_relative_to(plan_path.resolve().parent) or not c.is_dir() for c in companions):
        raise ValueError("Companion addons must exist alongside plan")
    for checked in (addon, *companions):
        if not is_valid(check_addon(checked)):
            return {"status": "failed", "error": f"Invalid addon sources in {checked.name}"}
    if cfg.automation_backend != "wowcontrol":
        raise ValueError("Sessions log in through the WoWControlSDK; set automation_backend = \"wowcontrol\"")
    from .wowcontrol import require_windows_transport
    require_windows_transport()  # Before deploying addon files or starting WoW.
    _credentials(wow)
    for deployed in (addon, *companions):
        deploy(deployed, wow)   # before the client starts, so it loads current code
    from . import clients
    clients.clear()
    if plan.get("member"):
        _credentials(wow, "member")   # fail before starting anything without member credentials
    prepared = prepare_environment(cfg, start_client=True, login=True,
                                   enter_character=plan["character"], observer=observer)
    expected_status = "sdk_character_observed" if observer == "sdk" else "character_verified"
    if prepared.get("status") != expected_status:
        return {"status": "infrastructure_error", "preparation": prepared}
    if plan.get("member"):
        from .wowcontrol import client_pid, launch_and_enter
        clients.register("main", client_pid(cfg))
        if plan.get("member_addons"):
            from .addon_settings import write_character_addons
            account, _ = _credentials(wow, "member")
            prepared["member_addons"] = str(write_character_addons(
                wow, account, cfg.wowcontrol_realm, plan["member"], plan["member_addons"]))
        try:
            prepared["member_pid"] = launch_and_enter(cfg, plan["member"], role="member")
        except RuntimeError as exc:
            return {"status": "infrastructure_error", "preparation": prepared,
                    "error": f"Member client for {plan['member']} did not enter the world: {exc}"}
    result = run_plan(cfg, plan_path, approve=True, deployed_before_start=True)
    return {"status": result["status"], "preparation": prepared, "plan_result": result,
            "closed_clients": closed}
