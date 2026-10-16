-- OPEN ITEMS: loot still waiting to be rolled, from the raid lead's ledger:
-- on the corpse (O lists), parked with a raider or kept by the master looter
-- (open awards), with their roll status.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local TOME = "|cffa335ee|Hitem:21281:0:0:0:0:0:0:0:60|h[Grimoire of Shadow Bolt]|h|r"
local BOOTS = "|cffa335ee|Hitem:20514:0:0:0:0:0:0:0:60|h[Abyssal Boots]|h|r"
local SESSION = "Lead-1792131000"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.item(21281, { name = "Grimoire of Shadow Bolt", link = TOME, quality = 4 })
    forge.item(20514, { name = "Abyssal Boots", link = BOOTS, quality = 4 })
    forge.setSaved("RaidWishlistDB", { chars = { Tester = { items = {
        { itemID = 20513, spec = "ms", priority = 1, note = "" },
        { itemID = 20514, spec = "ms", priority = 2, note = "" },
    } } } })
end)

local function receive(message)
    forge.fire("CHAT_MSG_ADDON", "FLLedger", message, "RAID", "Lead")
end

local function award(id, rev, itemID, recipient, state, spec, winner)
    receive(table.concat({ "A", SESSION, "Lead", id, rev, 1792131000 + id, itemID, "", recipient, state, 1,
        spec or "", spec and 50 or "", spec and 1 or "", spec and 100 or "", winner or "", 1, "", "21:0" .. id }, ";"))
end

test("loot on the corpse is listed, wishlisted items are marked", function()
    forge.raid({ "Lead", "Bob", "Tester" })
    forge.slash("/wish")
    expect(forge.findText("No loot is waiting to be rolled.")).toBeTruthy()
    receive("O;" .. SESSION .. ";Lead;20513:o:c:,21281:r:c:")
    expect(forge.findText("OPEN ITEMS (2)")).toBeTruthy()
    expect(forge.findText(CREST .. "  on the corpse")).toBeTruthy()
    expect(forge.findText("WISHLIST  OPEN")).toBeTruthy()
    expect(forge.findText("ROLLING NOW")).toBeTruthy()
    expect(forge.layoutIssues("RaidWishlistFrame")).toEqual({})
end)

test("a decided roll shows its winner", function()
    receive("O;" .. SESSION .. ";Lead;20513:w:c:Alice")
    expect(forge.findText("OPEN ITEMS (1)")).toBeTruthy()
    expect(forge.findText("WON: ALICE")).toBeTruthy()
end)

test("an item parked with a raider is open, not handed out", function()
    receive("O;" .. SESSION .. ";Lead;")
    award(5, 1, 20514, "Bob", "parked")
    expect(forge.findText(BOOTS .. "  with Bob")).toBeTruthy()
    expect(forge.findText("WISHLIST  OPEN")).toBeTruthy()
    expect(forge.findText("THIS RAID")).toBeTruthy()            -- not "THIS RAID (1)"
    expect(forge.findText("Nothing handed out yet.\nAwards appear here when the raid lead uses RaidLedger.")).toBeTruthy()
end)

test("rolling a parked item later shows it as rolling now", function()
    receive("O;" .. SESSION .. ";Lead;20514:r:a5:")
    expect(forge.findText("OPEN ITEMS (1)")).toBeTruthy()
    expect(forge.findText(BOOTS .. "  with Bob")).toBeTruthy()
    expect(forge.findText("WISHLIST  ROLLING NOW")).toBeTruthy()
end)

test("an item parked with you is not received: you still roll on it", function()
    award(6, 1, 20513, "Tester", "parked")
    expect(forge.findText(CREST .. "  with Tester")).toBeTruthy()
    expect(forge.saved("RaidWishlistDB").chars.Tester.items[1].received).toBeNil()
    expect(forge.findText("RECEIVED")).toBeNil()
end)

test("an item the master looter keeps without a roll is open too", function()
    award(7, 1, 21281, "Lead", "held")
    expect(forge.findText(TOME .. "  with Lead")).toBeTruthy()
    expect(forge.findText("OPEN ITEMS (3)")).toBeTruthy()
    expect(forge.layoutIssues("RaidWishlistFrame")).toEqual({})
end)

test("once the roll decides it, the award leaves the open list", function()
    award(5, 2, 20514, "Cara", "manual", "ms", "Cara")
    receive("O;" .. SESSION .. ";Lead;")
    expect(forge.findText("OPEN ITEMS (2)")).toBeTruthy()
    expect(forge.findText("THIS RAID (1)")).toBeTruthy()
    expect(forge.findText(BOOTS .. "  ->  Cara")).toBeTruthy()
end)

test("an older raid's open list is ignored", function()
    receive("O;Lead-1792120000;Lead;20513:o:c:")
    expect(forge.findText("OPEN ITEMS (2)")).toBeTruthy()
    expect(#forge.errors()).toBe(0)
end)
