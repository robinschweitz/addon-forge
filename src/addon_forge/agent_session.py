"""Windows approved QA session runner."""
from pathlib import Path
from .config import Config
from .scenario_plan import load_plan

def run_session(cfg: Config, plan_path: Path, *, approve: bool = False):
    plan = load_plan(plan_path)
    if not approve:
        return {"status": "plan_only", "plan": plan}
    raise RuntimeError("Unattended session not yet validated")
