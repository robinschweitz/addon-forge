"""Offline layer: Lua 5.1 analysis, static API checks and the headless harness."""
from pathlib import Path

import pytest

from addon_forge import wowapi
from addon_forge.headless import run_addon, run_specs
from addon_forge.lua51 import global_accesses, syntax_error
from addon_forge.validate import check_addon, is_valid

ROOT = Path(__file__).resolve().parents[1]


def addon(tmp_path, lua, *, name="Probe", toc_extra="", spec=None):
    root = tmp_path / name
    root.mkdir()
    (root / f"{name}.toc").write_text(f"## Interface: 30300\n{toc_extra}{name}.lua\n", encoding="utf-8")
    (root / f"{name}.lua").write_text(lua, encoding="utf-8")
    if spec is not None:
        (root / "tests").mkdir()
        (root / "tests" / "probe.spec.lua").write_text(spec, encoding="utf-8")
    return root


@pytest.fixture(autouse=True)
def no_client_dump(monkeypatch, tmp_path):
    # Tests must not depend on whether a developer has dumped their client.
    monkeypatch.setattr(wowapi, "DUMP_PATH", tmp_path / "no-dump.txt")
    monkeypatch.setattr(wowapi, "known_globals", lambda path=None: None)


def test_lua52_syntax_is_rejected():
    assert syntax_error(b"goto done", "x.lua")
    assert syntax_error(b"local x = 7 // 2", "x.lua")
    assert syntax_error(b"local x = 1 return x", "x.lua") is None


def test_bytecode_reports_globals_fields_and_methods_with_lines():
    found = global_accesses(b"local t = C_Timer.After\nFoo = 1\nlocal f = {} f:SetColorTexture(1,1,1)\n", "x.lua")
    assert ("get", "C_Timer", 1, "After") in [(a.kind, a.name, a.line, a.field) for a in found]
    assert ("set", "Foo", 2) in [(a.kind, a.name, a.line) for a in found]
    assert any(a.method == "SetColorTexture" and a.line == 3 for a in found)


def test_static_check_flags_modern_and_lua52_apis(tmp_path):
    root = addon(tmp_path, "C_Timer.After(1, print)\nif IsInGroup() then end\nlocal x = table.unpack({})\n"
                           "local tex = UIParent:CreateTexture() tex:SetColorTexture(1, 0, 0)\ncount = 1\n")
    diags = check_addon(root)
    text = "\n".join(d.message for d in diags)
    assert not is_valid(diags)
    assert "Probe.lua:1: C_Timer" in text
    assert "IsInGroup" in text and "GetNumPartyMembers" in text
    assert "table.unpack" in text
    assert "SetColorTexture" in text
    assert any(d.severity == "warning" and "'count'" in d.message for d in diags)


def test_static_check_accepts_real_addons():
    for path in ("examples/ForgeExample", "wow/ForgeTestBridge"):
        assert is_valid(check_addon(ROOT / path)), path


def test_unknown_global_needs_client_dump(tmp_path, monkeypatch):
    root = addon(tmp_path, "local x = GetMadeUpThing()\nlocal y = CreateFrame('Frame')\n")
    assert not any("GetMadeUpThing" in d.message for d in check_addon(root))
    monkeypatch.setattr(wowapi, "known_globals", lambda path=None: frozenset({"CreateFrame"}))
    diags = check_addon(root)
    assert any(d.severity == "warning" and "GetMadeUpThing" in d.message for d in diags)
    assert not any("CreateFrame" in d.message for d in diags)


def test_saved_variables_load_after_files_like_the_client(tmp_path):
    root = addon(tmp_path, """
local seenAtFileLoad = ProbeDB
local f = CreateFrame("Frame", "ProbeFrame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(self, event, name)
    if name == "Probe" then ProbeDB = ProbeDB or { loads = 0 }; ProbeDB.loads = ProbeDB.loads + 1
        ProbeDB.fileLoadSaw = seenAtFileLoad ~= nil end
end)
""", toc_extra="## SavedVariables: ProbeDB\n", spec="""
before_load(function() forge.setSaved("ProbeDB", { loads = 4 }) end)
test("saved variables are not visible while files execute", function()
    expect(forge.saved("ProbeDB").loads).toBe(5)
    expect(forge.saved("ProbeDB").fileLoadSaw).toBe(false)
    forge.reload()
    expect(forge.saved("ProbeDB").loads).toBe(6)
end)
""")
    result = run_specs(root)
    assert result["status"] == "passed", result


def test_failures_are_reported_not_hidden(tmp_path):
    root = addon(tmp_path, """
local f = CreateFrame("Frame", "ProbeFrame", UIParent)
f:RegisterEvent("PLAYER_TARGET_CHANGED")
f:SetScript("OnEvent", function() local broken = nil; return broken.field end)
SLASH_PROBE1 = "/probe"
SlashCmdList.PROBE = function() f:Hide() end
""", spec="""
test("wrong expectation fails", function() expect(1 + 1).toBe(3) end)
test("handler error fails the test", function() forge.fire("PLAYER_TARGET_CHANGED") end)
test("slash command works", function() forge.slash("/probe") expect("ProbeFrame").toBeHidden() end)
""")
    run = run_specs(root)["runs"][1]
    status = {t["name"]: t for t in run["tests"]}
    assert status["wrong expectation fails"]["status"] == "failed"
    assert "expected 3, got 2" in status["wrong expectation fails"]["error"]
    assert status["handler error fails the test"]["status"] == "failed"
    assert "attempt to index" in status["handler error fails the test"]["errors"][0]
    assert status["slash command works"]["status"] == "passed"


def test_load_error_and_modern_api_call_fail_the_run(tmp_path):
    root = addon(tmp_path, "local n = GetNumGroupMembers()\n")
    result = run_addon(root)
    assert result["status"] == "failed"
    assert "GetNumGroupMembers" in result["load_errors"][0]
    assert any(d["severity"] == "error" and "GetNumGroupMembers" in d["message"] for d in result["diagnostics"])


def test_onupdate_runs_only_for_visible_frames(tmp_path):
    root = addon(tmp_path, """
ProbeTicks = 0
local f = CreateFrame("Frame", "ProbeFrame", UIParent)
f:SetScript("OnUpdate", function(self, elapsed) ProbeTicks = ProbeTicks + elapsed end)
""", spec="""
test("hidden frames do not tick", function()
    forge.advance(1, 0.5)
    expect(ProbeTicks).toBe(1)
    forge.frame("ProbeFrame"):Hide()
    forge.advance(1, 0.5)
    expect(ProbeTicks).toBe(1)
end)
""")
    assert run_specs(root)["status"] == "passed"


def test_sandbox_blocks_host_access_and_infinite_loops(tmp_path):
    root = addon(tmp_path, "ProbeHost = { os = os, io = io, python = python, require = require }\n", spec="""
test("no host libraries", function()
    expect(ProbeHost.os).toBeNil()
    expect(ProbeHost.io).toBeNil()
    expect(ProbeHost.python).toBeNil()
    expect(ProbeHost.require).toBeNil()
    expect(loadstring(string.dump(function() end))).toBeNil()
end)
test("infinite loop is stopped", function() while true do end end)
""")
    run = run_specs(root)["runs"][1]
    assert run["tests"][0]["status"] == "passed", run["tests"][0]
    assert "instruction budget" in run["tests"][1]["error"]


def test_spec_files_are_not_deployed_or_loaded(tmp_path):
    root = addon(tmp_path, "local x = 1\n", spec="test('x', function() end)\n")
    assert not any("tests/" in d.message for d in check_addon(root))


def test_forge_loot_ledger_reference_addon_passes_all_specs():
    result = run_specs(ROOT / "examples" / "ForgeLootLedger")
    assert result["status"] == "passed", result


def test_client_method_dump_makes_missing_widget_methods_fail_like_the_client(tmp_path, monkeypatch):
    root = addon(tmp_path, """
local b = CreateFrame("Button", "ProbeButton", UIParent)
if b.SetTextColor then ProbeDetected = true end
b:SetTextColor(1, 1, 1)
""")
    monkeypatch.setattr(wowapi, "known_methods", lambda path=None: {
        "Button": frozenset({"SetText", "GetText", "CreateFontString", "Click", "SetScript", "Show", "Hide",
                             "IsShown", "IsVisible", "GetName", "GetObjectType", "SetFontString", "GetFontString"}),
        "FontString": frozenset({"SetText", "GetText", "SetTextColor"})})
    result = run_addon(root)
    assert result["status"] == "failed"
    assert "attempt to call method 'SetTextColor'" in result["load_errors"][0]
    assert any(d["severity"] == "error" and "Button:SetTextColor()" in d["message"] for d in result["diagnostics"])


def test_feature_detection_read_of_missing_method_is_not_an_error(tmp_path, monkeypatch):
    root = addon(tmp_path, "local f = CreateFrame('Frame') if f.GetText then f:GetText() end\n")
    monkeypatch.setattr(wowapi, "known_methods", lambda path=None: {"Frame": frozenset({"Show", "Hide"})})
    result = run_addon(root)
    assert result["status"] == "passed", result
    assert any(d["severity"] == "info" and "Frame:GetText" in d["message"] for d in result["diagnostics"])


def test_layout_check_finds_overlap_overflow_and_respects_explicit_lines(tmp_path):
    root = addon(tmp_path, """
local f = CreateFrame("Frame", "ProbeFrame", UIParent)
f:SetWidth(200) f:SetHeight(100) f:SetPoint("CENTER")
f:SetBackdrop({ insets = { left = 3, right = 3, top = 3, bottom = 3 } })
local a = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
a:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -10) a:SetText("HEADER")
ProbeB = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
ProbeB:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -12) ProbeB:SetText("OVERLAPPING")
local wide = CreateFrame("Button", "ProbeWide", f) wide:SetWidth(250) wide:SetHeight(10)
wide:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 10)
local two = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
two:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -40) two:SetText("line one\\nline two")
""", spec="""
test("issues", function()
    local issues = forge.layoutIssues("ProbeFrame")
    expect(table.concat(issues, "|")).toContain('FontString "HEADER" overlaps FontString "OVERLAPPING"')
    expect(table.concat(issues, "|")).toContain("ProbeWide sticks out of ProbeFrame")
    expect(#issues).toBe(2)
    local r = forge.rect("ProbeFrame")
    expect(r.width).toBe(200)
    expect(select(4, ProbeFrame:GetRect())).toBe(100)
    ProbeB:Hide()
    forge.frame("ProbeWide"):SetWidth(100)
    expect(forge.layoutIssues("ProbeFrame")).toEqual({})
end)
""")
    result = run_specs(root)
    assert result["status"] == "passed", result["runs"][1]
