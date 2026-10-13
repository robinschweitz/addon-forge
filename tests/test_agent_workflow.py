import json
from pathlib import Path
from types import SimpleNamespace
import pytest

from addon_forge.agent_workflow import run_plan
from addon_forge.config import Config


def setup_plan(tmp_path, peers=0):
    addon = tmp_path / "ForgeExample"
    addon.mkdir()
    (addon / "ForgeExample.toc").write_text("## Interface: 30300\nForgeExample.lua\n")
    (addon / "ForgeExample.lua").write_text("local frame = CreateFrame('Frame')\n")
    plan = tmp_path / "acceptance.json"
    plan.write_text(json.dumps({
        "version":1, "addon":"ForgeExample","character":"Forgechar",
        "peers":peers,"checks":[{"type":"player_in_world","value":True}]
    }))
    cfg=Config(wow_dir=tmp_path/"test-wow",wine_prefix=tmp_path/"wine",
               realm_dir=tmp_path/"realm")
    return cfg,plan


def test_preview_does_not_mutate_or_open_wow(tmp_path, monkeypatch):
    cfg, plan=setup_plan(tmp_path,1)
    def never(*args,**kwargs):
        pytest.fail("preview may not modify game")
    monkeypatch.setattr("addon_forge.agent_workflow.deploy",never)
    monkeypatch.setattr("addon_forge.agent_workflow.peer_scenario",never)
    assert run_plan(cfg,plan)["status"]=="plan_only"


def test_report_success_requires_independent_snapshot(tmp_path, monkeypatch):
    cfg,plan=setup_plan(tmp_path)
    monkeypatch.setattr("addon_forge.agent_workflow.check_addon", lambda p: [])
    monkeypatch.setattr("addon_forge.agent_workflow.deploy",lambda *args:None)
    mock=SimpleNamespace(status="passed",run_id="abc",details={
       "report":{"completed":True,"snapshot":{"player":{"exists":True}}}})
    monkeypatch.setattr("addon_forge.agent_workflow.run_smoke",lambda *a,**k:mock)
    result=run_plan(cfg,plan,approve=True)
    assert result["status"]=="passed"


def test_no_telemetry_never_passes(tmp_path,monkeypatch):
    cfg,plan=setup_plan(tmp_path)
    monkeypatch.setattr("addon_forge.agent_workflow.check_addon",lambda p:[])
    monkeypatch.setattr("addon_forge.agent_workflow.deploy",lambda *a:None)
    mock=SimpleNamespace(status="passed",run_id="abc",details={
       "report":{"completed":True}})
    monkeypatch.setattr("addon_forge.agent_workflow.run_smoke",lambda *a,**k:mock)
    result=run_plan(cfg,plan,approve=True)
    assert result["status"]=="infrastructure_error"
