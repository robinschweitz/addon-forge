"""Real-client smoke runs, with strict report correlation and timeouts."""
from dataclasses import asdict, dataclass
from pathlib import Path
import json
import time
import uuid

from .client import ClientController
from .config import Config
from .reports import latest_report


@dataclass
class TestResult:
    status: str  # passed | failed | infrastructure_error
    run_id: str
    details: dict


def run_smoke(cfg: Config, suite: str = "smoke", out_dir: Path | None = None,
              required_tests: tuple[str, ...] = ()) -> TestResult:
    if not suite.isalnum():
        raise ValueError("Suite name must be alphanumeric")
    client = ClientController(cfg)
    run_id = uuid.uuid4().hex[:12]
    previous = latest_report(cfg.wow_dir)
    prior_mtime = previous[0].stat().st_mtime_ns if previous else 0
    client.command(f"/forge run {suite} {run_id}")
    # Tests run synchronously inside the slash handler. Allow UI updates before flushing.
    time.sleep(1)
    client.command("/reload")
    report = None
    until = time.monotonic() + cfg.report_timeout
    while time.monotonic() < until:
        time.sleep(0.5)
        entry = latest_report(cfg.wow_dir)
        if entry and entry[0].stat().st_mtime_ns > prior_mtime and entry[1].get("runId") == run_id:
            report = entry[1]
            break
    if report is None:
        result = TestResult("infrastructure_error", run_id, {"error": "Missing matching SavedVariables report; confirm client is in-world and ForgeTestBridge is enabled"})
    else:
        tests = report.get("tests", [])
        if not report.get("completed") or not isinstance(tests, list) or not tests:
            result = TestResult("infrastructure_error", run_id, {"error": "Report contains no completed tests", "report": report})
        else:
            passed = all(isinstance(test, dict) and test.get("status") == "passed" for test in tests)
            errors = report.get("errors", [])
            seen_names = {t.get("name") for t in tests if isinstance(t, dict)}
            missing = sorted(set(required_tests) - seen_names)
            status = "passed" if passed and not errors and not missing else "failed"
            result = TestResult(status, run_id, {"report": report, "missing_required_tests": missing})
    if out_dir:
        out_dir.mkdir(parents=True, exist_ok=True)
        (out_dir / f"{run_id}.json").write_text(json.dumps(asdict(result), indent=2), encoding="utf-8")
        try:
            client.screenshot(out_dir / f"{run_id}.png")
        except (OSError, RuntimeError):
            pass  # Screenshot collection cannot turn a test result into a pass.
    return result
