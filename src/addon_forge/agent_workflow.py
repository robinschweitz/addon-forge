"""Orchestrate a bounded, independent addon acceptance scenario.

Order: static checks -> offline headless specs -> deploy -> optional fixtures
-> in-client bridge suite -> independent snapshot checks. Any earlier stage
failing stops the run before it spends real-client time.
"""
from __future__ import annotations
from contextlib import ExitStack
from dataclasses import asdict
from pathlib import Path

from .config import Config
from .peer_scenario import peer_scenario
from .runner import run_smoke
from .scenario_plan import load_plan, evaluate, slash_commands, watch_paths
from .deploy import deploy, differs
from .validate import check_addon, is_valid

BRIDGE_VERSION = 3
# The bridge has a versioned reporting contract; plans always install this copy.
BRIDGE_SRC = Path(__file__).resolve().parents[2] / "wow" / "ForgeTestBridge"


def _offline(addon: Path) -> dict:
    from .headless import run_specs
    result = run_specs(addon)
    # Keep the agent-facing summary small; full runs are available via 'forge spec'.
    failures = [{"spec": r["spec"], "load_errors": r["load_errors"], "errors": r["errors"],
                 "failed_tests": [t for t in r["tests"] if t.get("status") != "passed"],
                 "diagnostics": [d for d in r["diagnostics"] if d["severity"] == "error"]}
                for r in result["runs"] if r["status"] != "passed"]
    return {"status": result["status"], "specs": result["specs"], "tests": result["tests"],
            "passed": result["passed"], "failures": failures}


def _step_screenshot(cfg: Config, evidence_dir: Path, name: str, client: str = "main") -> Path:
    from .windows_client import WindowsClientController
    evidence_dir.mkdir(parents=True, exist_ok=True)
    suffix = "" if client == "main" else "-" + client
    return WindowsClientController(cfg, role=client).screenshot(evidence_dir / f"step-{name}{suffix}.png")


def _member_suite(cfg: Config, plan: dict, evidence_dir: Path) -> dict:
    """Run the bridge suite on the member client and judge it like the main one."""
    import uuid
    from .runner import judge
    from .wowcontrol import bridge_run, client_pid
    owners = (plan["addon"], *plan.get("companions", ()))
    run_id = uuid.uuid4().hex[:12]
    try:
        report = bridge_run(cfg, "smoke", run_id, watch_paths(plan, "member"), pid=client_pid(cfg, "member"))
        result = asdict(judge(report, run_id, ("bridge_loaded",), owners))
    except RuntimeError as exc:
        return {"status": "infrastructure_error", "run_id": run_id, "details": {"error": str(exc)}}
    try:
        _step_screenshot(cfg, evidence_dir, run_id, "member")
    except (OSError, RuntimeError):
        pass  # evidence only
    return result


def run_plan(cfg: Config, plan_file: Path, *, approve: bool = False,
             deployed_before_start: bool = False) -> dict:
    plan = load_plan(plan_file)
    addon = (plan_file.parent / plan["addon"]).resolve()
    # Must be inside the scenario directory. No user-controlled paths inside plan.
    if not addon.is_relative_to(plan_file.parent.resolve()) or not addon.is_dir():
        raise ValueError(f"Addon folder {addon} not found alongside the scenario")
    companions = [(plan_file.parent / name).resolve() for name in plan.get("companions", [])]
    for companion in companions:
        if not companion.is_relative_to(plan_file.parent.resolve()) or not companion.is_dir():
            raise ValueError(f"Companion addon folder {companion} not found alongside the scenario")
    addons = [addon, *companions]
    owners = tuple(a.name for a in addons)
    observer = plan.get("observer", "bridge")
    if observer == "sdk" and cfg.automation_backend != "wowcontrol":
        raise ValueError("SDK observer requires wowcontrol backend")
    operations = ["Validate addon sources", "Run offline headless specs", "Deploy into isolated WoW copy"]
    if companions:
        operations[2] = "Deploy into isolated WoW copy (with " + ", ".join(c.name for c in companions) + ")"
    if plan.get("fixtures"):
        operations.append("Run fixtures: " + ", ".join(plan["fixtures"]))
    if plan["peers"]:
        operations.append(f"Run {plan['peers']} AzerothGhost peer(s)")
    if plan.get("steps"):
        operations.append("Run steps: " + ", ".join(f"{s['type']} {s['value']}" for s in plan["steps"]))
    if plan.get("member"):
        operations.append(f"Second player: {plan['member']} on a second test client (member credentials)")
        if plan.get("member_addons"):
            operations.append(f"{plan['member']} loads only: " + ", ".join(plan["member_addons"])
                              + " (and the test bridge)")
    operations += ["Run in-game bridge suite", "Check independent snapshot assertions"]
    preview = {"plan": plan, "addon_dir": str(addon), "operations": operations}
    if plan.get("steps"):
        from .plan_steps import addon_slash_commands
        known = set().union(*(addon_slash_commands(a) for a in addons))
        unknown = slash_commands(plan) - known
        if unknown:
            raise ValueError(f"Steps may only run the addon's own slash commands; "
                             f"{sorted(unknown)} are not defined by {plan['addon']}")
    if not approve:
        return {"status": "plan_only", **preview}
    for checked in addons:
        errors = check_addon(checked)
        if not is_valid(errors):
            return {"status": "failed", "stage": "static", "error": f"Static validation failed for {checked.name}",
                    "diagnostics": [asdict(x) for x in errors]}
    offline = _offline(addon)
    for companion in companions:
        result = _offline(companion)
        if result["status"] != "passed":
            offline = {**result, "addon": companion.name}
            break
    if offline["status"] != "passed":
        return {"status": "failed", "stage": "offline", **preview, "offline": offline,
                "error": "Offline specs failed; fix them before spending a real-client run"}
    # A running client keeps the code it loaded at startup: testing after a
    # deploy that changed files would judge the OLD addon.
    stale = [p.name for p in (*addons, BRIDGE_SRC) if differs(p, cfg.wow_dir)]
    for deployed in addons:
        deploy(deployed, cfg.wow_dir)
    if observer != "sdk":
        deploy(BRIDGE_SRC, cfg.wow_dir)
    if stale and not deployed_before_start:
        return {"status": "infrastructure_error", "stage": "deploy", **preview, "offline": offline,
                "deployed": stale,
                "error": f"Deployed changed files for {', '.join(stale)}, but the running test client "
                         "still has the previous version loaded. Close WoW and run "
                         "'forge agent session PLAN --approve-fixtures' (deploys before starting the "
                         "client), or restart the client and rerun this plan."}
    if observer == "sdk":
        from .sdk_observer import run_sdk_observations
        return {**preview, "offline": offline, **run_sdk_observations(cfg, plan)}
    evidence_dir = addon.parent / ".forge-runs"
    paths = watch_paths(plan)
    fixtures = {}
    step_log = []
    peer = None
    member_test = None
    with ExitStack() as stack:
        if "master_loot" in plan.get("fixtures", []):
            from .loot_scenario import master_loot_fixture
            try:
                fixtures["master_loot"] = stack.enter_context(
                    master_loot_fixture(cfg, character=plan["character"], output=evidence_dir,
                                        member=plan.get("member")))
                peer = fixtures["master_loot"].pop("peer", None)
            except RuntimeError as exc:
                return {"status": "infrastructure_error", "stage": "fixture", **preview,
                        "offline": offline, "error": f"master_loot fixture failed: {exc}"}
        if plan.get("steps"):
            from .plan_steps import StepFailed, run_steps
            from .wowcontrol import client_pid
            try:
                pids = {"member": client_pid(cfg, "member")} if plan.get("member") else None
                step_log = run_steps(plan["steps"], client_pid(cfg), peer=peer, pids=pids,
                                     screenshot=lambda name, client="main": _step_screenshot(
                                         cfg, evidence_dir, name, client))
            except StepFailed as exc:
                return {"status": "failed", "stage": "steps", **preview, "offline": offline,
                        "steps": getattr(exc, "log", []),
                        "fixtures": fixtures, "error": str(exc)}
        # Newly deployed addons need a reload or restart and must be enabled. Stop
        # instead of treating an unregistered addon as success.
        if plan["peers"]:
            run = peer_scenario(cfg, character=plan["character"], approve=True,
                                peers=plan["peers"], suite="peer",
                                required_tests=("peer_target_visible",),
                                output_dir=evidence_dir, paths=paths, owner=owners)
            test = run.get("report", {})
        else:
            result = run_smoke(cfg, suite="smoke", required_tests=("bridge_loaded",),
                               out_dir=evidence_dir, paths=paths, owner=owners)
            test = asdict(result)
            member_test = _member_suite(cfg, plan, evidence_dir) if plan.get("member") else None
    if test.get("status") != "passed":
        return {"status": test.get("status", "infrastructure_error"), **preview, "offline": offline,
                "fixtures": fixtures, "test": test, "error": "Client or fixture assertions did not pass"}
    report = test.get("details", {}).get("report")
    if not isinstance(report, dict):
        return {"status": "infrastructure_error", **preview,
                "error": "Missing correlated test report"}
    if report.get("bridgeVersion") != BRIDGE_VERSION or report.get("schemaVersion") != BRIDGE_VERSION:
        return {"status": "infrastructure_error", **preview, "test": test,
                "error": f"Old ForgeTestBridge loaded; plans need bridge v{BRIDGE_VERSION}. "
                         "Close and restart the test WoW client after deploying the bridge."}
    independent = evaluate(plan, report)
    if plan.get("member"):
        member_report = (member_test or {}).get("details", {}).get("report")
        if (member_test or {}).get("status") != "passed" or not isinstance(member_report, dict):
            return {"status": (member_test or {}).get("status", "infrastructure_error"), **preview,
                    "offline": offline, "fixtures": fixtures, "steps": step_log, "test": test,
                    "member_test": member_test, "error": "The member client's bridge suite did not pass"}
        member_checks = evaluate(plan, member_report, "member")
        independent = {"status": "passed" if independent["status"] == member_checks["status"] == "passed"
                       else "failed", "checks": independent["checks"] + member_checks["checks"]}
        test["member_run_id"] = member_test.get("run_id")
    status = independent["status"]
    return {"status": status, **preview, "offline": offline, "fixtures": fixtures, "steps": step_log,
            "test": test, "independent": independent, "evidence_dir": str(evidence_dir)}
