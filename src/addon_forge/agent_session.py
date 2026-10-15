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
    from .windows_client import WindowsAPI, _client_binary
    from .deploy import deploy
    from .agent_prepare import prepare_environment
    from .agent_workflow import run_plan
    from .validate import check_addon, is_valid
    import sys
    if sys.platform != "win32":
        raise RuntimeError("Native Windows is required")
    wow = _test_copy(cfg.wow_dir)
    api = WindowsAPI()
    try:
        api.find_window(cfg.window_name, _client_binary(wow))
    except RuntimeError as exc:
        if "found 0." not in str(exc):
            raise
    else:
        raise RuntimeError("Close test WoW before starting the session")

    addon = (plan_path.resolve().parent / plan["addon"]).resolve()
    if not addon.is_relative_to(plan_path.resolve().parent) or not addon.is_dir():
        raise ValueError("Scenario addon must exist alongside plan")
    if not is_valid(check_addon(addon)):
        return {"status": "failed", "error": "Invalid addon sources"}
    if cfg.automation_backend != "wowcontrol":
        raise ValueError("Sessions log in through the WoWControlSDK; set automation_backend = \"wowcontrol\"")
    from .wowcontrol import require_windows_transport
    require_windows_transport()  # Before deploying addon files or starting WoW.
    _credentials(wow)
    deploy(addon, wow)
    prepared = prepare_environment(cfg, start_client=True, login=True,
                                   enter_character=plan["character"], observer=observer)
    expected_status = "sdk_character_observed" if observer == "sdk" else "character_verified"
    if prepared.get("status") != expected_status:
        return {"status": "infrastructure_error", "preparation": prepared}
    result = run_plan(cfg, plan_path, approve=True, deployed_before_start=True)
    return {"status": result["status"], "preparation": prepared, "plan_result": result}
