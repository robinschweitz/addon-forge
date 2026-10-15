"""`forge new`: a 3.3.5a addon skeleton with an offline spec and acceptance plan."""
from __future__ import annotations

import json
from pathlib import Path
import re

NAME = re.compile(r"[A-Z][A-Za-z0-9]{2,39}\Z")

TOC = """## Interface: 30300
## Title: {name}
## Notes: {notes}
## Author: Addon Forge
## Version: 0.1.0
## SavedVariables: {name}DB
Core.lua
"""

CORE = """-- {name}: WoW 3.3.5a (Lua 5.1). Only APIs that exist on build 12340.
local addonName, ns = ...
local DB_VERSION = 1

local frame = CreateFrame("Frame", "{name}Frame", UIParent)
frame:SetWidth(240)
frame:SetHeight(80)
frame:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
frame:SetBackdrop({{
    bgFile = "Interface\\\\Tooltips\\\\UI-Tooltip-Background",
    edgeFile = "Interface\\\\Tooltips\\\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = {{ left = 3, right = 3, top = 3, bottom = 3 }},
}})
frame:SetBackdropColor(0.02, 0.03, 0.06, 0.95)
frame:EnableMouse(true)
frame:SetMovable(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

local status = frame:CreateFontString("{name}Status", "OVERLAY", "GameFontNormal")
status:SetPoint("CENTER", frame, "CENTER", 0, 0)
status:SetText("{name} loading")

local function onLoaded()
    {name}DB = {name}DB or {{}}
    {name}DB.version = DB_VERSION
    {name}DB.logins = ({name}DB.logins or 0) + 1
    status:SetText("{name} ready")
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        onLoaded()
    elseif event == "PLAYER_LOGIN" then
        -- Optional test bridge: lets acceptance plans observe this frame.
        if ForgeTestBridge and ForgeTestBridge.RegisterFrame then
            ForgeTestBridge:RegisterFrame("{name}Frame", self)
            ForgeTestBridge:RegisterFrame("{name}Status", status)
        end
    end
end)

SLASH_{upper}1 = "/{lower}"
SlashCmdList["{upper}"] = function(message)
    local command = string.lower(strtrim(message or ""))
    if command == "" or command == "toggle" then
        if frame:IsShown() then frame:Hide() else frame:Show() end
    else
        DEFAULT_CHAT_FRAME:AddMessage("{name}: /{lower} [toggle]")
    end
end
"""

SPEC = """-- Offline spec for {name}. Run with: forge spec projects/{name}
before_load(function()
    forge.setSaved("{name}DB", {{ logins = 2 }})
end)

test("SavedVariables are migrated and counted on load", function()
    local db = forge.saved("{name}DB")
    expect(db.version).toBe(1)
    expect(db.logins).toBe(3)
    expect(forge.text("{name}Status")).toBe("{name} ready")
end)

test("/{lower} toggles the window", function()
    expect("{name}Frame").toBeShown()
    forge.slash("/{lower}")
    expect("{name}Frame").toBeHidden()
    forge.slash("/{lower} toggle")
    expect("{name}Frame").toBeShown()
end)

test("unknown subcommands print usage", function()
    forge.slash("/{lower} nope")
    expect(forge.lastChat()).toContain("/{lower} [toggle]")
end)

test("login count survives /reload", function()
    forge.reload()
    expect(forge.saved("{name}DB").logins).toBe(4)
end)
"""


def new_addon(name: str, *, root: Path = Path("projects"), character: str = "Test",
              notes: str = "Created with Addon Forge") -> dict:
    if not NAME.fullmatch(name):
        raise ValueError("Addon names start with a capital letter: 3-40 letters/digits, e.g. RaidTimer")
    if not re.fullmatch(r"[A-Za-z]{2,12}", character):
        raise ValueError("Invalid test character name")
    addon = root / name
    plan = root / f"{name}-acceptance.json"
    if addon.exists() or plan.exists():
        raise FileExistsError(f"{addon} or {plan} already exists; refusing to overwrite")
    (addon / "tests").mkdir(parents=True)
    fill = {"name": name, "upper": name.upper(), "lower": name.lower(),
            "notes": notes.replace("\n", " ")[:120]}
    (addon / f"{name}.toc").write_text(TOC.format(**fill), encoding="utf-8")
    (addon / "Core.lua").write_text(CORE.format(**fill), encoding="utf-8")
    (addon / "tests" / f"{name}.spec.lua").write_text(SPEC.format(**fill), encoding="utf-8")
    acceptance = {"version": 1, "addon": name, "character": character, "peers": 0, "checks": [
        {"type": "player_in_world", "value": True},
        {"type": "frame_visible", "value": f"{name}Frame"},
        {"type": "frame_text_contains", "frame": f"{name}Status", "value": "ready"},
        {"type": "global_equals", "path": f"{name}DB.version", "value": 1},
        {"type": "no_lua_errors", "value": True},
    ]}
    plan.write_text(json.dumps(acceptance, indent=2) + "\n", encoding="utf-8")
    return {"addon": str(addon), "plan": str(plan),
            "next": [f"forge check {addon}", f"forge spec {addon}",
                     f"forge --config forge.local.toml agent run-plan {plan}"]}
