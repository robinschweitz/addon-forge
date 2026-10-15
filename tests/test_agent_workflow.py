import json
from pathlib import Path
from addon_forge.runner import TestResult
import pytest

from addon_forge.agent_workflow import run_plan
from addon_forge.config import Config
from addon_forge.scenario_plan import evaluate, validate_plan, watch_paths


def setup_plan(tmp_path, peers=0, checks=None, spec=None, **extra):
    addon = tmp_path / "ForgeExample"
    addon.mkdir(parents=True)
    (addon / "ForgeExample.toc").write_text("## Interface: 30300\nForgeExample.lua\n")
    (addon / "ForgeExample.lua").write_text("local frame = CreateFrame('Frame')\n")
    if spec:
        (addon / "tests").mkdir()
        (addon / "tests" / "x.spec.lua").write_text(spec)
    plan = tmp_path / "acceptance.json"
    plan.write_text(json.dumps({
        "version":1, "addon":"ForgeExample","character":"Forgechar",
        "peers":peers,"checks":checks or [{"type":"player_in_world","value":True}], **extra
    }))
    cfg=Config(wow_dir=tmp_path/"test-wow",wine_prefix=tmp_path/"wine",
               realm_dir=tmp_path/"realm")
    return cfg,plan


def report(snapshot=None, **extra):
    body = {"completed": True, "bridgeVersion": 3, "schemaVersion": 3, **extra}
    if snapshot is not None:
        body["snapshot"] = snapshot
    return TestResult(status="passed", run_id="abc", details={"report": body})


def test_preview_does_not_mutate_or_open_wow(tmp_path, monkeypatch):
    cfg, plan=setup_plan(tmp_path,1)
    def never(*args,**kwargs):
        pytest.fail("preview may not modify game")
    monkeypatch.setattr("addon_forge.agent_workflow.deploy",never)
    monkeypatch.setattr("addon_forge.agent_workflow.peer_scenario",never)
    result = run_plan(cfg,plan)
    assert result["status"]=="plan_only"
    assert "Run offline headless specs" in result["operations"]


def test_report_success_requires_independent_snapshot(tmp_path, monkeypatch):
    cfg,plan=setup_plan(tmp_path)
    monkeypatch.setattr("addon_forge.agent_workflow.check_addon", lambda p: [])
    monkeypatch.setattr("addon_forge.agent_workflow.deploy",lambda *args:None)
    monkeypatch.setattr("addon_forge.agent_workflow.differs", lambda *a: False)
    monkeypatch.setattr("addon_forge.agent_workflow.run_smoke",
                        lambda *a,**k:report({"player":{"exists":True}}))
    result=run_plan(cfg,plan,approve=True)
    assert result["status"]=="passed"
    assert result["offline"]["status"] == "passed"


def test_no_telemetry_never_passes(tmp_path,monkeypatch):
    cfg,plan=setup_plan(tmp_path)
    monkeypatch.setattr("addon_forge.agent_workflow.check_addon",lambda p:[])
    monkeypatch.setattr("addon_forge.agent_workflow.deploy",lambda *a:None)
    monkeypatch.setattr("addon_forge.agent_workflow.run_smoke",lambda *a,**k:report())
    result=run_plan(cfg,plan,approve=True)
    assert result["status"]=="infrastructure_error"


def test_old_bridge_report_is_infrastructure_error(tmp_path, monkeypatch):
    cfg,plan=setup_plan(tmp_path)
    monkeypatch.setattr("addon_forge.agent_workflow.deploy",lambda *a:None)
    old = TestResult(status="passed", run_id="abc", details={"report": {
        "completed": True, "bridgeVersion": 2, "schemaVersion": 2, "snapshot": {"player": {"exists": True}}}})
    monkeypatch.setattr("addon_forge.agent_workflow.run_smoke",lambda *a,**k:old)
    assert run_plan(cfg,plan,approve=True)["status"] == "infrastructure_error"


def test_failing_offline_spec_stops_before_deploy(tmp_path, monkeypatch):
    cfg,plan=setup_plan(tmp_path, spec="test('broken', function() expect(1).toBe(2) end)\n")
    def never(*a, **k):
        pytest.fail("a failing offline spec must not reach the client")
    monkeypatch.setattr("addon_forge.agent_workflow.deploy", never)
    monkeypatch.setattr("addon_forge.agent_workflow.run_smoke", never)
    result = run_plan(cfg, plan, approve=True)
    assert result["status"] == "failed" and result["stage"] == "offline"
    assert result["offline"]["failures"][0]["failed_tests"][0]["name"] == "broken"


def test_watched_paths_reach_the_bridge_run(tmp_path, monkeypatch):
    checks = [{"type": "global_equals", "path": "ForgeExampleDB.count", "value": 2}]
    cfg,plan=setup_plan(tmp_path, checks=checks)
    monkeypatch.setattr("addon_forge.agent_workflow.deploy",lambda *a:None)
    monkeypatch.setattr("addon_forge.agent_workflow.differs", lambda *a: False)
    seen = {}
    def fake_run(*a, **k):
        seen["paths"] = k["paths"]
        return report({"values": {"ForgeExampleDB.count": 2}})
    monkeypatch.setattr("addon_forge.agent_workflow.run_smoke", fake_run)
    assert run_plan(cfg,plan,approve=True)["status"] == "passed"
    assert seen["paths"] == ("ForgeExampleDB.count",)


BASE = {"version": 1, "addon": "X1", "character": "Test", "peers": 0}


def test_new_checks_are_strict_about_keys_and_values():
    ok = validate_plan({**BASE, "checks": [
        {"type": "frame_text_contains", "frame": "XFrame", "value": "ready"},
        {"type": "global_equals", "path": "XDB.history.1.item", "value": "Abyssal Crest"},
        {"type": "chat_contains", "value": "won by"},
        {"type": "event_fired", "value": "LOOT_OPENED"},
        {"type": "no_lua_errors", "value": True}]})
    assert watch_paths(ok) == ("XDB.history.1.item",)
    for bad in ({"type": "global_equals", "path": "XDB[1]", "value": 1},
                {"type": "global_equals", "path": "XDB.a", "value": {"nested": 1}},
                {"type": "frame_text_contains", "value": "x"},
                {"type": "event_fired", "value": "loot_opened"},
                {"type": "chat_contains", "value": "line\nbreak"},
                {"type": "no_lua_errors", "value": False}):
        with pytest.raises(ValueError):
            validate_plan({**BASE, "checks": [bad]})
    with pytest.raises(ValueError):
        validate_plan({**BASE, "fixtures": ["teleport"], "checks": [{"type": "player_in_world", "value": True}]})
    with pytest.raises(ValueError):
        validate_plan({**BASE, "peers": 1, "fixtures": ["master_loot"],
                       "checks": [{"type": "player_in_world", "value": True}]})


def test_evaluate_new_checks_against_snapshot():
    plan = validate_plan({**BASE, "checks": [
        {"type": "frame_text_contains", "frame": "XFrame", "value": "ready"},
        {"type": "global_equals", "path": "XDB.count", "value": 3},
        {"type": "global_equals", "path": "XDB.flag", "value": True},
        {"type": "global_equals", "path": "XDB.gone", "value": None},
        {"type": "chat_contains", "value": "won by Bob"},
        {"type": "event_fired", "value": "LOOT_OPENED"},
        {"type": "no_lua_errors", "value": True}]})
    good = {"completed": True, "errors": {}, "snapshot": {
        "frames": {"XFrame": {"shown": True, "text": "X ready"}},
        "values": {"XDB.count": 3, "XDB.flag": True}, "chat": ["[Loot] crest won by Bob (97)."],
        "events": {"LOOT_OPENED": 2}}}
    assert evaluate(plan, good)["status"] == "passed"
    bad = {"completed": True, "errors": ["Core.lua:3: boom"], "snapshot": {
        "frames": {"XFrame": {"shown": True, "text": "X loading"}},
        "values": {"XDB.count": "3", "XDB.flag": 1, "XDB.gone": 0}, "chat": {}, "events": {}}}
    checks = evaluate(plan, bad)["checks"]
    assert [c["passed"] for c in checks] == [False] * 7


def test_other_addons_errors_do_not_fail_this_addon():
    from addon_forge.runner import judge
    from addon_forge.scenario_plan import split_errors
    foreign = "Interface\\AddOns\\ForgeLootLedger\\ForgeLootLedger.lua:158: attempt to call method 'SetTextColor'"
    own = "Interface\\AddOns\\ForgeExample\\ForgeExample.lua:3: boom"
    bare = "[string \"x\"]:1: unattributed"
    assert split_errors([foreign, own, bare], "ForgeExample") == ([own, bare], [foreign])
    base = {"completed": True, "runId": "r1", "tests": [{"name": "bridge_loaded", "status": "passed"}]}
    ok = judge({**base, "errors": [foreign]}, "r1", owner="ForgeExample")
    assert ok.status == "passed" and ok.details["foreign_errors"] == [foreign]
    assert judge({**base, "errors": [foreign]}, "r1").status == "failed"   # no owner: strict
    assert judge({**base, "errors": [own]}, "r1", owner="ForgeExample").status == "failed"
    plan = validate_plan({**BASE, "addon": "ForgeExample", "checks": [{"type": "no_lua_errors", "value": True}]})
    assert evaluate(plan, {"completed": True, "errors": [foreign], "snapshot": {}})["status"] == "passed"


def test_changed_files_on_a_running_client_are_not_tested(tmp_path, monkeypatch):
    cfg, plan = setup_plan(tmp_path)
    monkeypatch.setattr("addon_forge.agent_workflow.deploy", lambda *a: None)
    def never(*a, **k):
        pytest.fail("stale client code must not be judged")
    monkeypatch.setattr("addon_forge.agent_workflow.run_smoke", never)
    result = run_plan(cfg, plan, approve=True)
    assert result["status"] == "infrastructure_error" and result["stage"] == "deploy"
    assert "ForgeExample" in result["deployed"] and "agent session" in result["error"]
    monkeypatch.setattr("addon_forge.agent_workflow.run_smoke",
                        lambda *a, **k: report({"player": {"exists": True}}))
    assert run_plan(cfg, plan, approve=True, deployed_before_start=True)["status"] == "passed"


def test_differs_ignores_specs_and_detects_changes(tmp_path):
    from addon_forge.deploy import differs
    addon = tmp_path / "src" / "Probe"
    (addon / "tests").mkdir(parents=True)
    (addon / "Probe.toc").write_text("## Interface: 30300\nProbe.lua\n")
    (addon / "Probe.lua").write_text("local x = 1\n")
    (addon / "tests" / "p.spec.lua").write_text("test('x', function() end)\n")
    installed = tmp_path / "wow" / "Interface" / "AddOns" / "Probe"
    assert differs(addon, tmp_path / "wow")
    installed.mkdir(parents=True)
    for name in ("Probe.toc", "Probe.lua"):
        (installed / name).write_bytes((addon / name).read_bytes())
    assert not differs(addon, tmp_path / "wow")
    (addon / "Probe.lua").write_text("local x = 2\n")
    assert differs(addon, tmp_path / "wow")


def test_steps_are_strictly_validated():
    ok = validate_plan({**BASE, "steps": [
        {"type": "slash", "value": "/x1 start"}, {"type": "wait", "value": 1.5},
        {"type": "roll", "value": [1, 100]}, {"type": "click", "value": "XAward"}],
        "checks": [{"type": "player_in_world", "value": True}]})
    assert [s["type"] for s in ok["steps"]] == ["slash", "wait", "roll", "click"]
    for bad in ({"type": "slash", "value": "/x1 start; /logout"}, {"type": "slash", "value": "say hi"},
                {"type": "roll", "value": [0, 100]}, {"type": "roll", "value": [50, 10]},
                {"type": "wait", "value": 61}, {"type": "wait", "value": True},
                {"type": "click", "value": "x'] os.exit()"}, {"type": "lua", "value": "print(1)"}):
        with pytest.raises(ValueError):
            validate_plan({**BASE, "steps": [bad], "checks": [{"type": "player_in_world", "value": True}]})
    with pytest.raises(ValueError, match="180"):
        validate_plan({**BASE, "steps": [{"type": "wait", "value": 60}] * 4,
                       "checks": [{"type": "player_in_world", "value": True}]})


def test_steps_may_only_run_the_addons_own_slash_commands(tmp_path):
    cfg, plan = setup_plan(tmp_path, steps=[{"type": "slash", "value": "/logout"}])
    with pytest.raises(ValueError, match="own slash commands"):
        run_plan(cfg, plan)
    (tmp_path / "ForgeExample" / "ForgeExample.lua").write_text(
        'SLASH_FORGEEXAMPLE1 = "/forgeexample"\nSlashCmdList.FORGEEXAMPLE = function() end\n')
    cfg2, plan2 = setup_plan(tmp_path / "ok", steps=[{"type": "slash", "value": "/forgeexample start"}])
    (tmp_path / "ok" / "ForgeExample" / "ForgeExample.lua").write_text(
        'SLASH_FORGEEXAMPLE1 = "/forgeexample"\nSlashCmdList.FORGEEXAMPLE = function() end\n')
    assert run_plan(cfg2, plan2)["status"] == "plan_only"


def test_step_runner_sends_fixed_lua_and_stops_on_failure():
    from addon_forge.plan_steps import StepFailed, run_steps
    codes, waits = [], []
    def rpc(method, params=None, *, expected_pid):
        codes.append(params["code"])
        return {"ok": True, "result": "hidden" if "ForgeTestBridge.frames" in params["code"] else "ok"}
    steps = [{"type": "slash", "value": "/forgeloot start"}, {"type": "wait", "value": 2},
             {"type": "roll", "value": [1, 100]}, {"type": "click", "value": "ForgeLootLedgerAward"},
             {"type": "roll", "value": [1, 100]}]
    with pytest.raises(StepFailed, match="Step 4 click 'ForgeLootLedgerAward' failed: hidden"):
        run_steps(steps, 9, rpc=rpc, sleep=waits.append)
    assert waits == [2] and len(codes) == 3
    assert 'local cmd, rest = "/forgeloot", "start"' in codes[0]
    assert codes[1] == "RandomRoll(1, 100) return 'ok'"


def test_failed_step_fails_the_plan_before_the_suite(tmp_path, monkeypatch):
    cfg, plan = setup_plan(tmp_path, steps=[{"type": "roll", "value": [1, 100]}])
    monkeypatch.setattr("addon_forge.agent_workflow.deploy", lambda *a: None)
    monkeypatch.setattr("addon_forge.agent_workflow.differs", lambda *a: False)
    monkeypatch.setattr("addon_forge.wowcontrol.client_pid", lambda cfg: 9)
    monkeypatch.setattr("addon_forge.plan_steps.request", lambda *a, **k: {"ok": False})
    def never(*a, **k):
        pytest.fail("suite must not run after a failed step")
    monkeypatch.setattr("addon_forge.agent_workflow.run_smoke", never)
    result = run_plan(cfg, plan, approve=True)
    assert result["status"] == "failed" and result["stage"] == "steps"
