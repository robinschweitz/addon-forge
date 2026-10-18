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
    foreign = "Interface\\AddOns\\RaidLedger\\RaidLedger.lua:158: attempt to call method 'SetTextColor'"
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
    steps = [{"type": "slash", "value": "/ledger start"}, {"type": "wait", "value": 2},
             {"type": "roll", "value": [1, 100]}, {"type": "click", "value": "RaidLedgerAward"},
             {"type": "roll", "value": [1, 100]}]
    with pytest.raises(StepFailed, match="Step 4 click 'RaidLedgerAward' failed: hidden"):
        run_steps(steps, 9, rpc=rpc, sleep=waits.append)
    assert waits == [2] and len(codes) == 3
    assert 'local cmd, rest = "/ledger", "start"' in codes[0]
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


def test_peer_and_screenshot_steps_are_validated():
    ok = validate_plan({**BASE, "fixtures": ["master_loot"], "steps": [
        {"type": "peer_roll", "value": [1, 100]}, {"type": "peer_trade", "value": 20513},
        {"type": "screenshot", "value": "roll_log"}],
        "checks": [{"type": "player_in_world", "value": True}]})
    assert [s["type"] for s in ok["steps"]] == ["peer_roll", "peer_trade", "screenshot"]
    for bad in ({"type": "peer_roll", "value": [0, 100]}, {"type": "peer_trade", "value": True},
                {"type": "peer_trade", "value": "20513"}, {"type": "peer_trade", "value": 0},
                {"type": "screenshot", "value": "../x"}, {"type": "screenshot", "value": ""}):
        with pytest.raises(ValueError):
            validate_plan({**BASE, "fixtures": ["master_loot"], "steps": [bad],
                           "checks": [{"type": "player_in_world", "value": True}]})
    with pytest.raises(ValueError, match="master_loot"):
        validate_plan({**BASE, "steps": [{"type": "peer_roll", "value": [1, 100]}],
                       "checks": [{"type": "player_in_world", "value": True}]})


class FakePeer:
    name = "Flobot"

    def __init__(self, results=None):
        self.sent, self.results = [], results or {}

    def send(self, action, **args):
        self.sent.append(action)
        return len(self.sent)

    def wait(self, number, timeout):
        return self.results.get(self.sent[number - 1], "ok")

    def wait_armed(self, number, timeout):
        self.sent.append("armed?")
        return "ok"

    def roll(self, low, high):
        self.sent.append(f"roll {low}-{high}")
        return "ok"


def lua_client(answers):
    codes = []
    def rpc(method, params=None, *, expected_pid):
        codes.append(params["code"])
        for needle, answer in answers:
            if needle in params["code"]:
                return {"ok": True, "result": answer}
        return {"ok": True, "result": "ok"}
    return rpc, codes


def test_peer_trade_runs_the_trade_handshake_in_order():
    from addon_forge.plan_steps import run_steps
    peer = FakePeer()
    rpc, codes = lua_client([("GetContainerNumSlots", "0:3")])
    log = run_steps([{"type": "peer_roll", "value": [1, 100]}, {"type": "peer_trade", "value": 20513}],
                    9, rpc=rpc, sleep=lambda s: None, peer=peer)
    assert [e["result"] for e in log] == ["ok", "ok"]
    assert peer.sent == ["roll 1-100", "open_trade", "armed?", "accept_trade"]
    assert "== '20513'" in codes[0]
    assert 'UnitName(\'party\' .. i) == "Flobot"' in codes[1]
    assert "PickupContainerItem(0, 3) ClickTradeButton(1)" in codes[3]
    assert codes[4] == "AcceptTrade() return 'ok'"


def test_peer_trade_reports_where_it_stopped():
    from addon_forge.plan_steps import StepFailed, run_steps
    step = [{"type": "peer_trade", "value": 20513}]
    rpc, _ = lua_client([("GetContainerNumSlots", "missing")])
    with pytest.raises(StepFailed, match="item_not_in_bags:missing"):
        run_steps(step, 9, rpc=rpc, sleep=lambda s: None, peer=FakePeer())
    rpc, _ = lua_client([("GetContainerNumSlots", "1:12")])
    with pytest.raises(StepFailed, match="bot_accept:trade_not_completed") as failure:
        run_steps(step, 9, rpc=rpc, sleep=lambda s: None,
                  peer=FakePeer({"accept_trade": "trade_not_completed:TRADE_CANCELED"}))
    assert failure.value.log[0]["result"].startswith("bot_accept:")
    with pytest.raises(StepFailed, match="no_fixture_peer"):
        run_steps(step, 9, rpc=rpc, sleep=lambda s: None)


def test_screenshot_step_saves_under_its_name():
    from addon_forge.plan_steps import StepFailed, run_steps
    shots = []
    log = run_steps([{"type": "screenshot", "value": "roll_log"}], 9, rpc=None,
                    screenshot=lambda name: shots.append(name) or Path(f"step-{name}.png"))
    assert shots == ["roll_log"] and log[0]["path"] == "step-roll_log.png"
    with pytest.raises(StepFailed, match="no_screenshot_support"):
        run_steps([{"type": "screenshot", "value": "x"}], 9, rpc=None)


def test_raid_lead_fixture_extends_master_loot():
    ok = validate_plan({**BASE, "fixtures": ["master_loot", "raid_lead"],
                        "checks": [{"type": "player_in_world", "value": True}]})
    assert ok["fixtures"] == ["master_loot", "raid_lead"]
    with pytest.raises(ValueError, match="raid_lead"):
        validate_plan({**BASE, "fixtures": ["raid_lead"], "checks": [{"type": "player_in_world", "value": True}]})


def test_boe_loot_fixture_extends_master_loot():
    ok = validate_plan({**BASE, "fixtures": ["master_loot", "boe_loot"],
                        "checks": [{"type": "player_in_world", "value": True}]})
    assert ok["fixtures"] == ["master_loot", "boe_loot"]
    with pytest.raises(ValueError, match="boe_loot"):
        validate_plan({**BASE, "fixtures": ["boe_loot"], "checks": [{"type": "player_in_world", "value": True}]})


def test_companions_and_paste_steps_are_validated():
    ok = validate_plan({**BASE, "companions": ["X2"], "steps": [
        {"type": "paste", "value": ["XImport", "WL1;Test;1\n20513;ms;20;1;Crest"]}],
        "checks": [{"type": "player_in_world", "value": True}]})
    assert ok["companions"] == ["X2"] and ok["steps"][0]["type"] == "paste"
    for bad in ({"companions": ["X1"]}, {"companions": ["../X2"]}, {"companions": ["A", "B", "C", "D"]},
                {"companions": ["X2", "X2"]},
                {"steps": [{"type": "paste", "value": ["XImport", "a|Hitem"]}]},
                {"steps": [{"type": "paste", "value": ["XImport", ""]}]},
                {"steps": [{"type": "paste", "value": ["x'] os.exit()", "text"]}]},
                {"steps": [{"type": "paste", "value": ["XImport", "caf\u00e9"]}]}):
        with pytest.raises(ValueError):
            validate_plan({**BASE, **bad, "checks": [{"type": "player_in_world", "value": True}]})


def test_paste_step_sets_text_only_in_a_registered_edit_box():
    from addon_forge.plan_steps import run_steps
    codes = []
    def rpc(method, params=None, *, expected_pid):
        codes.append(params["code"])
        return {"ok": True, "result": "ok"}
    run_steps([{"type": "paste", "value": ["XImport", "WL1;Test;1\n20513;ms;20;1;\"Crest\""]}], 9, rpc=rpc)
    assert 'ForgeTestBridge.frames["XImport"]' in codes[0]
    assert "IsObjectType('EditBox')" in codes[0]
    assert 'f:SetText("WL1;Test;1\\n20513;ms;20;1;\\"Crest\\"")' in codes[0]


def test_companion_errors_count_for_the_plan():
    from addon_forge.scenario_plan import split_errors
    errors = ["Interface\\AddOns\\X2\\X2.lua:3: boom", "Interface\\AddOns\\Other\\o.lua:1: x"]
    owned, foreign = split_errors(errors, ("X1", "X2"))
    assert owned == [errors[0]] and foreign == [errors[1]]
    assert split_errors(errors, "X1") == ([], errors)


def test_companion_slash_commands_may_be_used_in_steps(tmp_path):
    cfg, plan = setup_plan(tmp_path, steps=[{"type": "slash", "value": "/xtwo start"}])
    data = json.loads(plan.read_text())
    data["companions"] = ["X2"]
    plan.write_text(json.dumps(data))
    with pytest.raises(ValueError, match="not found alongside"):
        run_plan(cfg, plan)
    (tmp_path / "X2").mkdir()
    (tmp_path / "X2" / "X2.lua").write_text('SLASH_XTWO1 = "/xtwo"\nSlashCmdList.XTWO = function() end\n')
    result = run_plan(cfg, plan)
    assert result["status"] == "plan_only"
    assert "with X2" in result["operations"][2]


def test_two_player_plans_are_validated():
    ok = validate_plan({**BASE, "member": "Raidmember", "steps": [
        {"type": "slash", "value": "/x1 start"}, {"type": "click", "value": "XRoll", "client": "member"}],
        "checks": [{"type": "player_in_world", "value": True},
                   {"type": "global_equals", "path": "XDB.a", "value": 1, "client": "member"}]})
    assert ok["member"] == "Raidmember"
    assert ok["steps"][1] == {"type": "click", "value": "XRoll", "client": "member"}
    assert ok["checks"][1]["client"] == "member"
    assert watch_paths(ok) == () and watch_paths(ok, "member") == ("XDB.a",)
    for bad in ({"member": "Test"}, {"member": "bad name"},
                {"steps": [{"type": "click", "value": "XRoll", "client": "member"}]},
                {"member": "Raidmember", "steps": [{"type": "click", "value": "XRoll", "client": "boss"}]},
                {"member": "Raidmember", "fixtures": ["master_loot"],
                 "steps": [{"type": "peer_roll", "value": [1, 100], "client": "member"}]}):
        with pytest.raises(ValueError):
            validate_plan({**BASE, **bad, "checks": [{"type": "player_in_world", "value": True}]})


def test_checks_are_judged_against_their_own_client_report():
    plan = validate_plan({**BASE, "member": "Raidmember", "checks": [
        {"type": "chat_contains", "value": "lead"},
        {"type": "chat_contains", "value": "member", "client": "member"}]})
    main = {"completed": True, "snapshot": {"chat": ["the lead said"]}}
    member = {"completed": True, "snapshot": {"chat": ["the member said"]}}
    assert [c["passed"] for c in evaluate(plan, main)["checks"]] == [True]
    judged = evaluate(plan, member, "member")["checks"]
    assert judged == [{"type": "chat_contains", "expected": "member", "actual": "the member said",
                       "passed": True, "client": "member"}]
    assert evaluate(plan, main, "member")["status"] == "failed"


def test_member_steps_run_on_the_member_client():
    from addon_forge.plan_steps import StepFailed, run_steps
    seen = []
    def rpc(method, params=None, *, expected_pid):
        seen.append(expected_pid)
        return {"ok": True, "result": "ok"}
    steps = [{"type": "slash", "value": "/wish"}, {"type": "slash", "value": "/wish", "client": "member"}]
    shots = []
    run_steps(steps + [{"type": "screenshot", "value": "s", "client": "member"}], 9, rpc=rpc,
              pids={"member": 12}, screenshot=lambda name, client="main": shots.append((name, client)) or name)
    assert seen == [9, 12] and shots == [("s", "member")]
    with pytest.raises(StepFailed, match="member client, which is not running"):
        run_steps(steps, 9, rpc=rpc)


def test_member_addons_are_validated():
    plan = {**BASE, "member": "Raidmember", "companions": ["X2"],
            "checks": [{"type": "player_in_world", "value": True}]}
    assert validate_plan({**plan, "member_addons": ["X1"]})["member_addons"] == ["X1"]
    for bad in (["Elsewhere"], [], ["X1", "X1"], "X1"):
        with pytest.raises(ValueError):
            validate_plan({**plan, "member_addons": bad})
    with pytest.raises(ValueError):
        validate_plan({**BASE, "member_addons": ["X1"], "checks": [{"type": "player_in_world", "value": True}]})


def test_member_character_loads_only_the_chosen_addons(tmp_path):
    from addon_forge.addon_settings import write_character_addons
    addons = tmp_path / "Interface" / "AddOns"
    for name in ("RaidLedger", "RaidWishlist", "ForgeTestBridge", "Blizzard_RaidUI"):
        (addons / name).mkdir(parents=True)
        (addons / name / f"{name}.toc").write_text("## Interface: 30300\n")
    (addons / "archive").mkdir()                       # no .toc: not an addon
    path = write_character_addons(tmp_path, "FORGEMEMBER", "AzerothCore", "Raidmember", ["RaidWishlist"])
    assert path == tmp_path / "WTF" / "Account" / "FORGEMEMBER" / "AzerothCore" / "Raidmember" / "AddOns.txt"
    assert path.read_text(encoding="utf-8").split() == [
        "ForgeTestBridge:", "enabled", "RaidLedger:", "disabled", "RaidWishlist:", "enabled"]
    with pytest.raises(ValueError):
        write_character_addons(tmp_path, "FORGEMEMBER", "AzerothCore", "../Test", ["RaidWishlist"])
    with pytest.raises(RuntimeError, match="not installed"):
        write_character_addons(tmp_path, "FORGEMEMBER", "AzerothCore", "Raidmember", ["Missing"])


def test_hardware_click_steps_are_validated():
    ok = validate_plan({**BASE, "steps": [{"type": "hardware_click", "value": "XCreate"}],
                        "checks": [{"type": "player_in_world", "value": True}]})
    assert ok["steps"] == [{"type": "hardware_click", "value": "XCreate"}]
    for bad in ("x'] os.exit()", "X Create", "", 7, ["XCreate"]):
        with pytest.raises(ValueError, match="hardware_click"):
            validate_plan({**BASE, "steps": [{"type": "hardware_click", "value": bad}],
                           "checks": [{"type": "player_in_world", "value": True}]})


def _click_rpc(bound, clicks):
    codes = []
    def rpc(method, params=None, *, expected_pid):
        code = params["code"]
        codes.append((expected_pid, code))
        if "SetBindingClick" in code:
            return {"ok": True, "result": bound}
        if "hardwareClicks[" in code and code.startswith("return"):
            return {"ok": True, "result": clicks.pop(0) if clicks else 0.0}
        return {"ok": True, "result": "ok"}
    return rpc, codes


def test_hardware_click_binds_presses_and_restores_the_key():
    from addon_forge.plan_steps import CLICK_KEY, run_steps
    presses = []
    rpc, codes = _click_rpc("bound:0:CLICK Other:LeftButton", [0.0, 1.0])
    log = run_steps([{"type": "hardware_click", "value": "XCreate"}], 9, rpc=rpc, sleep=lambda s: None,
                    press_click=lambda client="main": presses.append(client))
    assert log[0]["result"] == "ok" and presses == ["main"]
    bind = codes[0][1]
    assert 'local name, key = "XCreate", \'CTRL-SHIFT-F10\'' in bind and CLICK_KEY == "CTRL-SHIFT-F10"
    assert "f:GetName() ~= name or _G[name] ~= f" in bind and "SetBindingClick(key, name, 'LeftButton')" in bind
    assert codes[-1][1] == "SetBinding('CTRL-SHIFT-F10', \"CLICK Other:LeftButton\") return 'ok'"


def test_hardware_click_fails_without_a_click_and_still_restores():
    from addon_forge.plan_steps import StepFailed, run_steps
    rpc, codes = _click_rpc("bound:2:", [])
    with pytest.raises(StepFailed, match="not_clicked"):
        run_steps([{"type": "hardware_click", "value": "XCreate"}], 9, rpc=rpc, sleep=lambda s: None,
                  press_click=lambda client="main": None)
    assert codes[-1][1] == "SetBinding('CTRL-SHIFT-F10') return 'ok'"

    def broken(client="main"):
        raise RuntimeError("WoW is not the active window")
    rpc, codes = _click_rpc("bound:0:", [])
    with pytest.raises(StepFailed, match="key_press_failed"):
        run_steps([{"type": "hardware_click", "value": "XCreate"}], 9, rpc=rpc, press_click=broken)
    assert codes[-1][1] == "SetBinding('CTRL-SHIFT-F10') return 'ok'"


def test_hardware_click_presses_nothing_for_an_unusable_frame():
    from addon_forge.plan_steps import StepFailed, run_steps
    presses = []
    for answer in ("missing", "hidden", "no_global_name", "bind_failed"):
        rpc, codes = _click_rpc(answer, [])
        with pytest.raises(StepFailed, match=answer):
            run_steps([{"type": "hardware_click", "value": "XCreate"}], 9, rpc=rpc,
                      press_click=lambda client="main": presses.append(client))
        assert len(codes) == 1
    with pytest.raises(StepFailed, match="no_hardware_input"):
        run_steps([{"type": "hardware_click", "value": "XCreate"}], 9, rpc=_click_rpc("bound:0:", [])[0])
    assert presses == []


def test_hardware_click_on_the_member_client():
    from addon_forge.plan_steps import run_steps
    presses = []
    rpc, codes = _click_rpc("bound:0:", [1.0])
    run_steps([{"type": "hardware_click", "value": "XCreate", "client": "member"}], 9, rpc=rpc,
              sleep=lambda s: None, pids={"member": 12},
              press_click=lambda client="main": presses.append(client))
    assert presses == ["member"] and {pid for pid, _ in codes} == {12}
