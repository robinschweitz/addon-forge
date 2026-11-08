-- FR-RW-010 (user decision 2026-11-06): RaidWishlist keeps the raids it saw,
-- THIS RAID can show an earlier one, and received marks, the tally and roll
-- prompts still use only the raid it follows.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local TOME = "|cffa335ee|Hitem:21281:0:0:0:0:0:0:0:60|h[Grimoire of Shadow Bolt]|h|r"
local MONDAY, TODAY = "Lead-1792131000", "Lead-1792735000"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.item(21281, { name = "Grimoire of Shadow Bolt", link = TOME, quality = 4 })
end)

local function db() return forge.saved("RaidWishlistDB") end

local function receive(message, sender)
    forge.fire("CHAT_MSG_ADDON", "FLLedger", message, "RAID", sender or "Lead")
end

local function lastPopup()
    local popups = forge.popups()
    return popups[#popups]
end

local function showRaidTab()
    if not RaidWishlistFrame:IsShown() then forge.slash("/wish") end
    forge.click("RaidWishlistTabraid")
end

test("FR-RW-010 a newer raid keeps the last raid's awards", function()
    forge.raid({ "Lead", "Tester" })
    forge.slash("/wish")
    forge.click("RaidWishlistImportOpen")
    forge.type("RaidWishlistImportText", "WL2;Tester;1792130000;20\n20513;ms;1;1;BiS")
    forge.click("RaidWishlistImportButton")
    forge.slash("/wish auto off")
    receive("A;" .. MONDAY .. ";Lead;7;1;1792131007;20513;;Tester;given;1;ms;50;1;100;Tester;1;;21:07")
    receive("A;" .. MONDAY .. ";Lead;8;1;1792131100;21281;;Lead;given;1;os;40;1;100;Lead;1;;21:09")
    receive("A;" .. TODAY .. ";Lead;9;1;1792735100;21281;;Lead;given;1;ms;30;1;100;Lead;1;;20:10")
    expect(db().raid.session).toBe(TODAY)
    expect(#db().pastRaids).toBe(1)
    expect(db().pastRaids[1].session).toBe(MONDAY)
    expect(db().pastRaids[1].awards["lead:7"].recipient).toBe("Tester")
    expect(db().raid.awards["lead:7"]).toBeNil()
end)

test("FR-RW-010 a correction of a kept raid updates that raid only", function()
    local popups = #forge.popups()
    receive("A;" .. MONDAY .. ";Lead;7;2;1792131007;20513;;Lead;given;1;ms;50;1;100;Lead;1;;21:07;1")
    expect(db().pastRaids[1].awards["lead:7"].recipient).toBe("Lead")
    expect(db().raid.session).toBe(TODAY)
    expect(#forge.popups()).toBe(popups)
    receive("A;" .. MONDAY .. ";Lead;7;3;1792131007;20513;;Tester;given;1;ms;50;1;100;Tester;1;;21:07;1")
end)

test("FR-RW-010 THIS RAID shows an earlier raid on request", function()
    showRaidTab()
    expect(RaidWishlistRaidPane.heading:GetText()).toContain("(1)")
    local tally = forge.text("RaidWishlistRaidTally")
    forge.click("RaidWishlistRaidOlder")
    expect(RaidWishlistRaidPane.heading:GetText()).toContain("(2)")
    expect(forge.text("RaidWishlistRaid1")).toContain("Grimoire")
    expect(forge.text("RaidWishlistRaid2")).toContain("Abyssal")
    expect(forge.shown("RaidWishlistRaidTally")).toBe(false)   -- the tally is this raid's
    expect(#forge.layoutIssues(RaidWishlistFrame)).toBe(0)
    forge.sketch("past-raid", RaidWishlistFrame)
    -- Monday's crest does not count as received now.
    forge.click("RaidWishlistTabwish")
    expect(forge.findText("RECEIVED")).toBeNil()
    receive("S;" .. TODAY .. ";Lead;Lead-1792735200-1;20513;30;1;")
    expect("RaidWishlistPrompt").toBeShown()
    expect(forge.findText("already received")).toBeNil()
    forge.click("RaidWishlistSkip")
    showRaidTab()                          -- leaving the tab went back to this raid
    expect(RaidWishlistRaidPane.heading:GetText()).toContain("(1)")
    forge.click("RaidWishlistRaidOlder")
    forge.click("RaidWishlistRaidNewer")
    expect(RaidWishlistRaidPane.heading:GetText()).toContain("(1)")
    expect(forge.text("RaidWishlistRaidTally")).toBe(tally)
    expect(forge.shown("RaidWishlistRaidTally")).toBe(true)
end)

test("FR-RW-010 a ledger that continues an older raid asks to follow it", function()
    receive("R;" .. MONDAY .. ";Lead")
    expect(lastPopup().which).toBe("RAIDWISHLIST_FOLLOW_RAID")
    StaticPopupDialogs["RAIDWISHLIST_FOLLOW_RAID"].OnAccept(nil, lastPopup().data)
    expect(db().raid.session).toBe(MONDAY)
    expect(db().raid.awards["lead:7"].recipient).toBe("Tester")   -- its awards came back
    expect(db().pastRaids[1].session).toBe(TODAY)
    expect(#db().pastRaids).toBe(1)
end)

test("FR-RW-010 the player chooses how many raids to keep", function()
    forge.click("RaidWishlistSettingsOpen")
    forge.type("RaidWishlistKeepRaids", "1")
    forge.click("RaidWishlistReminderSave")
    expect(db().keepRaids).toBe(1)
    receive("A;Lead-1793000000;Lead;10;1;1793000100;21281;;Lead;given;1;ms;30;1;100;Lead;1;;20:10")
    receive("A;Lead-1794000000;Lead;11;1;1794000100;21281;;Lead;given;1;ms;30;1;100;Lead;1;;20:10")
    expect(#db().pastRaids).toBe(1)
    expect(db().pastRaids[1].session).toBe("Lead-1793000000")
    forge.click("RaidWishlistSettingsOpen")
    forge.type("RaidWishlistKeepRaids", "0")
    forge.click("RaidWishlistReminderSave")
    expect(db().keepRaids).toBe(1)                                -- at least one
end)
