-- The RAID tab with a full 25-player invite list (raider screenshot
-- 2026-10-24: the list was a narrow box ending above the attendance field,
-- SORT GROUPS floated under it, a wide empty strip on the right). The list
-- now fills the tab beside the left column, its bottom and SORT GROUPS line up
-- with the attendance field, and a larger window shows more of the list.
local NAMES = {
    "Schattenherz", "Morgenröte", "Eisenfaust", "Lichtbringer", "Donnerhuf", "Nachtfalke",
    "Feuerherz", "Sturmwind", "Blutmond", "Grimmbart", "Silberpfeil", "Frostbeule", "Dunkelwald",
    "Kriegsschrei", "Heiligenlied", "Steinhaut", "Waldläuferin", "Zornesglut", "Mondsichel",
    "Knochenmann", "Seelenfänger", "Glutfaust", "Runenwächter", "Elfenstaub", "Sternenfeuer",
}
local ROLES = { "TANK", "TANK", "HEAL", "HEAL", "HEAL", "HEAL", "HEAL" }

before_load(function()
    forge.locale("deDE", {})
end)

local function inviteList()
    local lines = { "RS2;INV;45;ICC 25 Donnerstag der Unerschütterlichen;25;2026-11-28;20:00" }
    for i, name in ipairs(NAMES) do
        lines[#lines + 1] = string.format("%s;%s;Krieger;0", name, ROLES[i] or "DD")
    end
    return table.concat(lines, "\n")
end

local function rect(name) return forge.rect(name) end

test("a full invite list fills the tab; its bottom lines up with the attendance field", function()
    forge.click("RaidLedgerRaidButton")
    forge.type("RaidLedgerInviteText", inviteList())
    forge.clickText("EINLESEN")
    forge.clickText("EXPORT")
    local panel, list = rect("RaidLedgerRaidPanel"), rect("RaidLedgerRaidMembers")
    expect(panel.right - list.right).toBe(12)
    -- The roster field's frame is the edit box's parent's parent (back > scroll > edit).
    local roster = rect(RaidLedgerRosterText:GetParent():GetParent())
    local sort = rect(forge.findText("GRUPPEN SORTIEREN"))   -- the button (its text's owner)
    expect(sort.bottom).toBe(roster.bottom)
    expect(sort.right).toBe(list.right)
    expect(list.bottom - sort.top).toBe(6)
    expect(list.top).toBe(rect(forge.findText("Einladungsliste", true)).top)
    -- 18 of the 25 fit at the default size; the wheel scrolls the rest.
    expect(forge.frame("RaidLedgerRaidMember18"):IsVisible()).toBe(true)
    expect(forge.frame("RaidLedgerRaidMember19")).toBeNil()
    forge.sketch("raid-tab", "RaidLedgerFrame")
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
end)

test("a taller window shows the whole list and a taller attendance field", function()
    local rosterBefore = rect(RaidLedgerRosterText:GetParent():GetParent()).height
    forge.drag("RaidLedgerResize", 200, -140)
    for i = 1, 25 do expect(forge.frame("RaidLedgerRaidMember" .. i):IsVisible()).toBe(true) end
    expect(forge.text(forge.frame("RaidLedgerRaidMember25").text)).toContain("Sternenfeuer")
    expect(rect(RaidLedgerRosterText:GetParent():GetParent()).height).toBe(rosterBefore + 140)
    local panel, list = rect("RaidLedgerRaidPanel"), rect("RaidLedgerRaidMembers")
    expect(panel.right - list.right).toBe(12)
    forge.sketch("raid-tab-large", "RaidLedgerFrame")
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
    expect(#forge.errors()).toBe(0)
end)
