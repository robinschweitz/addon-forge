-- An item received in last week's raid must not block its roll in the next
-- raid. The live release (2026-10-24) found it: the wishlist still counted the
-- old raid's award when the new raid's first roll started, because the roll
-- start is the first message of the new raid, and showed no prompt.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
end)

local function receive(message, sender)
    forge.fire("CHAT_MSG_ADDON", "FLLedger", message, "RAID", sender or "Lead")
end

test("last raid's award does not stop the next raid's roll prompt", function()
    forge.raid({ "Lead", "Tester" })
    forge.slash("/wish")
    forge.click("RaidWishlistImportOpen")
    forge.type("RaidWishlistImportText", "WL2;Tester;1792130000;20\n20513;ms;1;1;BiS")
    forge.click("RaidWishlistImportButton")
    forge.slash("/wish auto off")
    -- Last week: the crest went to Tester.
    receive("A;Lead-1792131000;Lead;7;1;1792131007;20513;;Tester;given;1;ms;50;1;100;Tester;1;;21:07")
    expect(forge.findText("ERHALTEN") or forge.findText("RECEIVED")).toBeTruthy()
    -- /reload keeps last week's raid in the SavedVariables.
    forge.reload()
    forge.raid({ "Lead", "Tester" })
    forge.slash("/wish")
    -- This week: a new raid; its first message is the crest's roll.
    receive("S;Lead-1792735000;Lead;Lead-1792735100-1;20513;30;1;")
    expect("RaidWishlistPrompt").toBeShown()
    expect(forge.findText("RECEIVED")).toBeNil()
end)

-- FR-RW-008 (user decision 2026-11-06): a roll start is a live event, so it
-- prompts whatever raid its ledger holds, but an older raid does not replace
-- the lists of the newer one.
test("a roll from an older raid still prompts and keeps the newer raid", function()
    forge.click("RaidWishlistRoll")
    receive("S;Lead-1792131000;Lead;Lead-1792131500-2;20513;30;1;")
    expect("RaidWishlistPrompt").toBeShown()
    expect(forge.saved("RaidWishlistDB").raid.session).toBe("Lead-1792735000")
    forge.click("RaidWishlistSkip")
end)

-- User report 2026-11-06: under group loot for trash, an assistant Alt+clicked
-- an item in the bags; the assistant's RaidLedger still held an older raid,
-- and no other raider got a prompt.
test("an assistant's bag roll from a ledger with an older raid prompts under group loot", function()
    forge.raid({ "Lead", "Roller", "Tester" })
    forge.stub("GetLootMethod", function() return "group" end)
    receive("O;Lead-1792735000;Lead;")
    receive("S;Roller-1792131000;Roller;Roller-1792735100-1;20513;30;1;", "Roller")
    expect("RaidWishlistPrompt").toBeShown()
    expect(forge.saved("RaidWishlistDB").raid.session).toBe("Lead-1792735000")
    -- A held award from that older raid does not join this raid's list.
    receive("A;Roller-1792131000;Roller;1;1;1792735100;20513;;Roller;held;1;;;;;;0;;02:00", "Roller")
    expect(forge.saved("RaidWishlistDB").raid.awards["roller:1"]).toBeNil()
    forge.click("RaidWishlistSkip")
end)

-- FR-RW-009 (user question 2026-11-06): show last Monday's loot on a
-- character whose wishlist follows a newer raid.
local OLD_AWARD = "A;Roller-1792131000;Roller;2;1;1792131100;20513;;Tester;given;1;ms;50;1;100;Tester;1;;21:02"

test("FR-RW-009 /wish sync offers to show an older raid's loot", function()
    local db = forge.saved("RaidWishlistDB")
    local popups = #forge.popups()
    -- Without a sync of the player's own, an older raid is dropped silently.
    receive(OLD_AWARD, "Roller")
    expect(#forge.popups()).toBe(popups)
    expect(db.raid.session).toBe("Lead-1792735000")

    forge.slash("/wish sync")
    receive(OLD_AWARD, "Roller")
    receive(OLD_AWARD, "Roller")                     -- one question per sync and raid
    expect(forge.chat()).toContain("RaidWishlist: Roller's ledger holds an older raid than the one shown.")
    expect(#forge.popups()).toBe(popups + 1)
    local popup = forge.popups()[#forge.popups()]
    expect(popup.which).toBe("RAIDWISHLIST_FOLLOW_RAID")
    expect(popup.text1).toBe("Roller")
    expect(db.raid.session).toBe("Lead-1792735000")  -- NO changes nothing

    local before = #forge.addonMessages()
    StaticPopupDialogs["RAIDWISHLIST_FOLLOW_RAID"].OnAccept(nil, popup.data)
    expect(db.raid.session).toBe("Roller-1792131000")
    expect(forge.addonMessages()[before + 1].message).toBe("Q;Roller-1792131000;Tester")
    receive(OLD_AWARD, "Roller")
    expect(db.raid.awards["roller:2"]).toBeTruthy()
    if not RaidWishlistFrame:IsShown() then forge.slash("/wish") end
    forge.click("RaidWishlistTabraid")
    expect(forge.findText("THIS RAID (1)") or forge.findText("DIESER RAID (1)")).toBeTruthy()
    expect(forge.layoutIssues("RaidWishlistFrame")).toEqual({})
end)
