"""Real-client suite runs, with strict report correlation and timeouts.

Windows (wowcontrol backend): the bridge report comes back as JSON in the same
SDK call. Wine/Linux: the legacy typed '/forge run' + '/reload' round trip
through SavedVariables.
"""
from dataclasses import asdict, dataclass
from pathlib import Path
import json
import sys
import time
import uuid

from .client import ClientController
from .config import Config
from .reports import latest_report, parse_report, ReportParseError


@dataclass
class TestResult:
    __test__ = False  # Not a pytest test class.
    status: str  # passed | failed | infrastructure_error
    run_id: str
    details: dict


def judge(report: dict, run_id: str, required_tests: tuple[str, ...] = (),
          owner: str | None = None) -> TestResult:
    """Strict pass/fail from a correlated bridge report.

    With `owner`, Lua errors raised by *other* enabled addons are reported as
    foreign_errors instead of failing this addon's run.
    """
    from .scenario_plan import split_errors
    tests = report.get("tests", [])
    if isinstance(tests, dict) and not tests:
        tests = []  # Lua encodes an empty list as {}.
    if report.get("runId") != run_id:
        return TestResult("infrastructure_error", run_id, {"error": "Report run id does not match", "report": report})
    if not report.get("completed") or not isinstance(tests, list) or not tests:
        return TestResult("infrastructure_error", run_id, {"error": "Report contains no completed tests", "report": report})
    passed = all(isinstance(test, dict) and test.get("status") == "passed" for test in tests)
    errors, foreign = split_errors(report.get("errors") or [], owner)
    seen_names = {t.get("name") for t in tests if isinstance(t, dict)}
    missing = sorted(set(required_tests) - seen_names)
    status = "passed" if passed and not errors and not missing else "failed"
    details = {"report": report, "missing_required_tests": missing}
    if errors:
        details["errors"] = errors
    if foreign:
        details["foreign_errors"] = foreign
    return TestResult(status, run_id, details)


def _savedvariables_report(cfg: Config, client, suite: str, run_id: str, paths: tuple[str, ...] = ()):
    from .wowcontrol import WATCH_PATH
    previous = latest_report(cfg.wow_dir)
    prior_mtime = previous[0].stat().st_mtime_ns if previous else 0
    # A typed chat line is short: the bridge collects watched paths one line at a time.
    for path in paths:
        if not WATCH_PATH.fullmatch(path):
            raise ValueError(f"Invalid watch path {path!r}")
        client.command(f"/forge watch {path}")
    client.command(f"/forge run {suite} {run_id}")
    # Tests run synchronously inside the slash handler. Allow UI updates before flushing.
    time.sleep(1)
    client.command("/reload")
    until = time.monotonic() + cfg.report_timeout
    while time.monotonic() < until:
        time.sleep(0.5)
        entry = latest_report(cfg.wow_dir)
        if entry and entry[0].stat().st_mtime_ns > prior_mtime and entry[1].get("runId") == run_id:
            return entry[1]
    return None


def _missing_report(cfg: Config, run_id: str) -> TestResult:
    root = cfg.wow_dir / "WTF" / "Account"
    entries = list(root.glob("*/SavedVariables/ForgeTestBridge.lua"))
    diagnostics = []
    for path in entries[:8]:
        try:
            parsed = parse_report(path.read_text(encoding="utf-8-sig"))
            diagnostics.append({"path": str(path), "run_id": parsed.get("runId"),
                                "completed": parsed.get("completed")})
        except (OSError, UnicodeError, ReportParseError) as exc:
            diagnostics.append({"path": str(path), "parse_error": type(exc).__name__})
    return TestResult("infrastructure_error", run_id, {
        "error": "Missing matching SavedVariables report; verify /forge run manually, then /reload",
        "report_files_found": len(entries), "reports": diagnostics,
        "hint": ("No saved report files: check that ForgeTestBridge is enabled and slash handler loaded"
                 if not entries else "Report files exist: check run ID and parser errors")
    })


def run_smoke(cfg: Config, suite: str = "smoke", out_dir: Path | None = None,
              required_tests: tuple[str, ...] = (), paths: tuple[str, ...] = (),
              owner: str | None = None) -> TestResult:
    if not suite.isalnum():
        raise ValueError("Suite name must be alphanumeric")
    run_id = uuid.uuid4().hex[:12]
    if sys.platform == "win32":
        if cfg.automation_backend != "wowcontrol":
            raise RuntimeError("Windows runs need the wowcontrol backend (forge agent wowcontrol-setup)")
        from .wowcontrol import bridge_run
        try:
            result = judge(bridge_run(cfg, suite, run_id, paths), run_id, required_tests, owner)
        except RuntimeError as exc:
            result = TestResult("infrastructure_error", run_id, {"error": str(exc)})
        client = None
    else:
        client = ClientController(cfg)
        report = _savedvariables_report(cfg, client, suite, run_id, paths)
        result = judge(report, run_id, required_tests, owner) if report else _missing_report(cfg, run_id)
    if out_dir:
        out_dir.mkdir(parents=True, exist_ok=True)
        (out_dir / f"{run_id}.json").write_text(json.dumps(asdict(result), indent=2), encoding="utf-8")
        try:
            (client or ClientController(cfg)).screenshot(out_dir / f"{run_id}.png")
        except (OSError, RuntimeError):
            pass  # Screenshot collection cannot turn a test result into a pass.
    return result
