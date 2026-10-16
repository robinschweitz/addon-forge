-- RaidWishlist: import, roll prompts and auto-rolls driven by the raid
-- lead's RaidLedger messages (prefix FLLedger), and who got what.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local TOME = "|cffa335ee|Hitem:21281:0:0:0:0:0:0:0:60|h[Grimoire of Shadow Bolt]|h|r"
local BOOTS = "|cffa335ee|Hitem:20514:0:0:0:0:0:0:0:60|h[Abyssal Boots]|h|r"

-- (Spec files run before the emulated world exists: no globals at top level.)
local WISHLIST = "WL2;Tester;1792130000;20\n"
    .. "21281;os;0;2;nice for alt spec\n"
    .. "20513;ms;1;1;BiS trinket\n"
    .. "20514;ms;0;3;\n"
    .. "99999;os;1;4;off spec cannot be enhanced\n"
    .. "garbage line"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.item(21281, { name = "Grimoire of Shadow Bolt", link = TOME, quality = 4 })
    forge.item(20514, { name = "Abyssal Boots", link = BOOTS, quality = 4 })
end)

local rolls = {}
local function stubRolls()
    forge.stub("RandomRoll", function(low, high) table.insert(rolls, { low, high }) end)
end

local function receive(message, sender)
    forge.fire("CHAT_MSG_ADDON", "FLLedger", message, "RAID", sender or "Lead")
end

local function rollStart(key, itemID, seconds, round, tied)
    receive(table.concat({ "S", "Lead-1792131000", "Lead", key, itemID, seconds or 30, round or 1, tied or "" }, ";"))
end

local function award(id, rev, itemID, recipient, state, spec, winner, session)
    receive(table.concat({ "A", session or "Lead-1792131000", "Lead", id, rev, 1792131000 + id, itemID, "",
        recipient, state, 1, spec or "", 50, 1, 100, winner or recipient, 1, "", "21:0" .. id }, ";"))
end

local function db() return forge.saved("RaidWishlistDB") end

test("the window starts hidden and /wish toggles it", function()
    expect("RaidWishlistFrame").toBeHidden()
    forge.slash("/wish")
    expect("RaidWishlistFrame").toBeShown()
    expect(forge.findText("No wishlist yet.\nCopy the export on the guild website, then IMPORT.")).toBeTruthy()
    expect(forge.layoutIssues("RaidWishlistFrame")).toEqual({})
end)

test("only this character's WL2 export is imported", function()
    forge.click("RaidWishlistImportOpen")
    expect("RaidWishlistImportPanel").toBeShown()
    forge.type("RaidWishlistImportText", "RS2;LOOT;1;x;1;1")
    forge.click("RaidWishlistImportButton")
    expect(forge.findText("That is not a wishlist export (it must start with WL2;). Export it again from the website.")).toBeTruthy()
    forge.type("RaidWishlistImportText", "WL2;Alice;1;0\n20513;ms;0;1;")
    forge.click("RaidWishlistImportButton")
    expect(forge.findText("This wishlist is for Alice. Log in with Alice to import it.")).toBeTruthy()
    expect(#db().chars.Tester.items).toBe(0)
end)

test("a valid export is imported in priority order; bad lines are skipped", function()
    forge.type("RaidWishlistImportText", WISHLIST)
    forge.click("RaidWishlistImportButton")
    expect("RaidWishlistImportPanel").toBeHidden()
    expect(forge.chat()).toContain("RaidWishlist: imported 3 wishlist items (2 invalid lines skipped).")
    local items = db().chars.Tester.items
    expect(items[1].itemID).toBe(20513)
    expect(items[1].enhanced).toBe(true)
    expect(items[2].spec).toBe("os")
    expect(forge.findText("MY WISHLIST (3)")).toBeTruthy()
    expect(forge.text(forge.findText("1. " .. CREST))).toBe("1. " .. CREST)
    expect(forge.findText("MS 21-120")).toBeTruthy()
    expect(forge.findText("OS 1-99")).toBeTruthy()
    expect(forge.layoutIssues("RaidWishlistFrame")).toEqual({})
end)

test("a roll on a wishlisted item opens a one-click prompt with the right range", function()
    stubRolls()
    forge.raid({ "Lead", "Alice" })
    rollStart("Lead-1-1", 20513)
    expect("RaidWishlistPrompt").toBeShown()
    expect(forge.findText("ROLL MS 21-120")).toBeTruthy()
    expect(forge.findText("Priority 1, MS 21-120  -  BiS trinket")).toBeTruthy()
    expect(forge.layoutIssues("RaidWishlistPrompt")).toEqual({})
    forge.click("RaidWishlistRoll")
    expect(rolls).toEqual({ { 21, 120 } })
    expect("RaidWishlistPrompt").toBeHidden()
end)

test("the same roll never prompts twice, skipping rolls nothing", function()
    rollStart("Lead-1-1", 20513)
    expect("RaidWishlistPrompt").toBeHidden()
    rollStart("Lead-1-2", 21281)
    expect(forge.findText("ROLL OS 1-99")).toBeTruthy()
    forge.clickText("SKIP")
    rollStart("Lead-1-2", 21281)
    expect("RaidWishlistPrompt").toBeHidden()
    expect(#rolls).toBe(1)
end)

test("items not on the wishlist and messages from outside the group are ignored", function()
    rollStart("Lead-1-3", 50000)
    expect("RaidWishlistPrompt").toBeHidden()
    receive("S;Lead-1792131000;Lead;Lead-1-4;20514;30;1;", "Stranger")
    expect("RaidWishlistPrompt").toBeHidden()
    expect(#forge.errors()).toBe(0)
end)

test("the prompt closes when the roll window ends", function()
    rollStart("Lead-1-5", 20514, 5)
    expect("RaidWishlistPrompt").toBeShown()
    forge.advance(6, 0.2)
    expect("RaidWishlistPrompt").toBeHidden()
    expect(#rolls).toBe(1)
end)

test("auto-roll rolls by itself after a moment, without a prompt", function()
    forge.click("RaidWishlistAuto")
    expect(forge.findText("AUTO-ROLL: ON")).toBeTruthy()
    rollStart("Lead-1-6", 20514)
    expect("RaidWishlistPrompt").toBeHidden()
    expect(#rolls).toBe(1)
    forge.advance(1.2, 0.2)
    expect(rolls[2]).toEqual({ 1, 100 })
    rollStart("Lead-1-6", 20514)
    forge.advance(1.2, 0.2)
    expect(#rolls).toBe(2)
end)

test("a tie-break only rolls for the tied players", function()
    rollStart("Lead-1-6", 20514, 15, 2, "Alice,Bob")
    forge.advance(1.2, 0.2)
    expect(#rolls).toBe(2)
    rollStart("Lead-1-6", 20514, 15, 2, "Alice,Tester")
    forge.advance(1.2, 0.2)
    expect(rolls[3]).toEqual({ 1, 100 })
end)

test("the raid list shows who got what, with your tally", function()
    award(1, 1, 21281, "Alice", "given", "ms")
    award(2, 1, 20513, "Tester", "given", "ms")
    expect(forge.findText("THIS RAID (2)")).toBeTruthy()
    expect(forge.findText(CREST .. "  ->  Tester")).toBeTruthy()
    expect(forge.findText("YOU: ITEMS 1 MS / 0 OS  |  TOKENS 0 MS / 0 OS")).toBeTruthy()
    expect(forge.findText("RECEIVED")).toBeTruthy()
    expect(forge.layoutIssues("RaidWishlistFrame")).toEqual({})
end)

test("received items are not rolled again", function()
    rollStart("Lead-1-7", 20513)
    forge.advance(1.2, 0.2)
    expect(#rolls).toBe(3)
end)

test("an item the master looter holds for you counts as yours", function()
    award(3, 1, 20514, "Lead", "held", "ms", "Tester")
    expect(forge.findText("YOU: ITEMS 2 MS / 0 OS  |  TOKENS 0 MS / 0 OS")).toBeTruthy()
    rollStart("Lead-1-8", 20514)
    forge.advance(1.2, 0.2)
    expect(#rolls).toBe(3)
end)

test("corrections replace older revisions; removed awards no longer count", function()
    award(2, 1, 20513, "Bob", "manual", "ms")         -- old revision: ignored
    expect(forge.findText(CREST .. "  ->  Tester")).toBeTruthy()
    award(2, 3, 20513, "Bob", "deleted", "ms")
    expect(forge.findText("YOU: ITEMS 1 MS / 0 OS  |  TOKENS 0 MS / 0 OS")).toBeTruthy()
    expect(forge.findText("REMOVED")).toBeTruthy()
end)

test("a newer raid replaces the list, an older one is ignored", function()
    award(1, 1, 21281, "Alice", "given", "os", nil, "Lead-1792139999")
    expect(forge.findText("THIS RAID (1)")).toBeTruthy()
    award(9, 1, 20513, "Zed", "given", "ms", nil, "Lead-1792130001")
    expect(forge.findText("THIS RAID (1)")).toBeTruthy()
end)

local function sentOfType(kind)
    local list = {}
    for _, m in ipairs(forge.addonMessages()) do
        if string.sub(m.message, 1, string.len(kind) + 1) == kind .. ";" then table.insert(list, m) end
    end
    return list
end

test("after login it asks the group once for this raid's awards; /wish sync asks again", function()
    local sent = sentOfType("Q")
    expect(#sent).toBe(1)                          -- earlier tests passed the 10 s login delay
    expect(string.match(sent[1].message, "^Q;[^;]+;Tester$")).toBeTruthy()
    expect(sent[1].prefix).toBe("FLLedger")
    expect(sent[1].chatType).toBe("RAID")
    forge.slash("/wish sync")
    expect(sentOfType("Q")[2].message).toBe("Q;Lead-1792139999;Tester")
end)

test("after login it shares the wishlist with the group, in rank order", function()
    local shared = sentOfType("W")
    expect(#shared >= 1).toBe(true)
    expect(shared[1].message).toBe("W;1792130000;1;1;20513:m:1:1,21281:o:0:2,20514:m:0:3")
    expect(shared[1].chatType).toBe("RAID")
end)

test("the wishlist and the auto-roll switch survive /reload", function()
    forge.reload()
    expect(#forge.saved("RaidWishlistDB").chars.Tester.items).toBe(3)
    expect(forge.saved("RaidWishlistDB").chars.Tester.auto).toBe(true)
    forge.slash("/wish auto off")
    expect(forge.saved("RaidWishlistDB").chars.Tester.auto).toBe(false)
end)

test("hovering a wishlist row shows the item and your wishlist entry", function()
    forge.slash("/wish")
    forge.hover(forge.findText("1. " .. CREST))
    local lines = forge.tooltip()
    expect(lines[1]).toBe("item:20513:0:0:0:0:0:0:0:80")
    expect(lines[2]).toBe("Wishlist: MS 21-120 - BiS trinket")
end)

test("the roll prompt sits above the raid lead's ledger, at the top of the screen", function()
    -- Live run 638949e7b728: the prompt covered RaidLedger's panes.
    local r = forge.rect("RaidWishlistPrompt")
    expect(r.top >= 690).toBe(true)
    expect(forge.frame("RaidWishlistPrompt"):GetFrameStrata()).toBe("FULLSCREEN_DIALOG")
end)


test("tokens are tallied in their own list", function()
    forge.raid({ "Lead", "Alice" })                  -- /reload above reset the group
    receive("A;Lead-1792139999;Lead;30;1;1792140000;47242;;Tester;given;1;ms;50;1;100;Tester;1;1;22:00")
    expect(forge.findText("YOU: ITEMS 0 MS / 0 OS  |  TOKENS 1 MS / 0 OS")).toBeTruthy()
    expect(forge.findText("MS TOKEN")).toBeTruthy()
    expect(forge.layoutIssues("RaidWishlistFrame")).toEqual({})
end)
