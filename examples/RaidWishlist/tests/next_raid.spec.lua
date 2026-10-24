-- An item received in last week's raid must not block its roll in the next
-- raid. The live release (2026-10-24) found it: the wishlist still counted the
-- old raid's award when the new raid's first roll started, because the roll
-- start is the first message of the new raid, and showed no prompt.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
end)

local function receive(message)
    forge.fire("CHAT_MSG_ADDON", "FLLedger", message, "RAID", "Lead")
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

test("a roll from an older raid than the one kept is ignored", function()
    forge.click("RaidWishlistRoll")
    receive("S;Lead-1792131000;Lead;Lead-1792131500-2;20513;30;1;")
    expect("RaidWishlistPrompt").toBeHidden()
end)
