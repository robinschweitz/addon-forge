"""Orchestrate a bounded, independent addon acceptance scenario."""
from __future__ import annotations
from dataclasses import asdict
from pathlib import Path

from .client import ClientController
from .config import Config
from .peer_scenario import peer_scenario
from .runner import run_smoke
from .scenario_plan import load_plan, evaluate
from .deploy import deploy
from .validate import check_addon, is_valid
from .reports import latest_report


def run_plan(cfg: Config, plan_file: Path, *, approve: bool = False) -> dict:
    plan = load_plan(plan_file)
    addon = (plan_file.parent / plan["addon"]).resolve()
    # Must be inside the scenario directory. No user-controlled paths inside plan.
    if not addon.is_relative_to(plan_file.parent.resolve()) or not addon.is_dir():
        raise ValueError(f"Addon folder {addon} not found alongside the scenario")
    preview = {"plan": plan, "addon_dir": str(addon),
               "operations": ["Validate addon sources", "Deploy into isolated WoW copy",
                              "Run optional 1-4 AzerothGhost peers", "Run in-game suite",
                              "Check independent snapshot assertions"]}
    if not approve:
        return {"status": "plan_only", **preview}
    errors = check_addon(addon)
    if not is_valid(errors):
        return {"status": "failed", "error": "Static validation failed",
                "diagnostics": [asdict(x) for x in errors]}
    deploy(addon, cfg.wow_dir)
    evidence_dir = addon.parent / ".forge-runs"
    # Newly deployed addons need a reload or restart and must be enabled. Stop
    # instead of treating an unregistered addon as success.
    if plan["peers"]:
        run = peer_scenario(cfg, character=plan["character"], approve=True,
                            peers=plan["peers"], suite="peer",
                            required_tests=("peer_target_visible",),
                            output_dir=evidence_dir)
        test = run.get("report", {})
    else:
        result = run_smoke(cfg, suite="smoke", required_tests=("bridge_loaded",),
                           out_dir=evidence_dir)
        test = asdict(result)
    if test.get("status") != "passed":
        return {"status": test.get("status", "infrastructure_error"), **preview,
                "test": test, "error": "Client or fixture assertions did not pass"}
    report = test.get("details", {}).get("report")
    if not isinstance(report, dict):
        return {"status": "infrastructure_error", **preview,
                "error": "Missing correlated test report"}
    independent = evaluate(plan, report)
    status = independent["status"]
    return {"status": status, **preview, "test": test, "independent": independent,
            "evidence_dir": str(evidence_dir)}
