"""Windows approved QA session runner."""
from pathlib import Path
from .config import Config
from .scenario_plan import load_plan

def run_session(cfg: Config, plan_path: Path, *, approve: bool = False):
    plan = load_plan(plan_path)
    if not approve:
        return {"status": "plan_only", "plan": plan}
    from .win_login import _test_copy, _read_calibration, _credentials
    from .win_character import read_character_calibration
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
