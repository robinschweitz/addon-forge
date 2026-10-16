-- RaidWishlist: enhanced rolls follow the website's rule X = min(EP, 50).
-- The WL2 export carries the EP balance; an enhanced win costs X until the
-- next export brings the new balance.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local BOOTS = "|cffa335ee|Hitem:20514:0:0:0:0:0:0:0:60|h[Abyssal Boots]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.item(20514, { name = "Abyssal Boots", link = BOOTS, quality = 4 })
end)

local rolls = {}

local function receive(message)
    forge.fire("CHAT_MSG_ADDON", "FLLedger", message, "RAID", "Lead")
end

local function rollStart(key, itemID)
    receive(table.concat({ "S", "Lead-1792131000", "Lead", key, itemID, 30, 1, "" }, ";"))
end

-- award shares an award like the ledger does (fields 14/15 are the roll range).
local function award(id, rev, winner, state, low, high)
    receive(table.concat({ "A", "Lead-1792131000", "Lead", id, rev, 1792131000 + id, 30000, "",
        winner, state, 1, "ms", low + 40, low, high, winner, 1, "", "21:0" .. id }, ";"))
end

local function import(text)
    forge.click("RaidWishlistImportOpen")
    forge.type("RaidWishlistImportText", text)
    forge.click("RaidWishlistImportButton")
end

test("an enhanced wish rolls 1+X..100+X with X = min(balance, 50)", function()
    forge.stub("RandomRoll", function(low, high) table.insert(rolls, { low, high }) end)
    forge.raid({ "Lead", "Alice" })
    forge.slash("/wish")
    import("WL2;Tester;1792130000;70\n20513;ms;1;1;\n20514;ms;0;2;")
    expect(forge.findText("MS 51-150")).toBeTruthy()
    expect(forge.findText("MS 1-100")).toBeTruthy()
    rollStart("Lead-1-1", 20513)
    forge.click("RaidWishlistRoll")
    expect(rolls).toEqual({ { 51, 150 } })
end)

test("an enhanced win lowers the balance; another player's win does not", function()
    award(1, 1, "Alice", "given", 51, 150)
    expect(forge.findText("MS 51-150")).toBeTruthy()
    award(2, 1, "Tester", "given", 51, 150)
    expect(forge.findText("MS 21-120")).toBeTruthy()
    -- A revision of the same award does not charge twice.
    award(2, 2, "Tester", "given", 51, 150)
    expect(forge.findText("MS 21-120")).toBeTruthy()
end)

test("a deleted award gives the points back; a new export resets the count", function()
    award(2, 3, "Tester", "deleted", 51, 150)
    expect(forge.findText("MS 51-150")).toBeTruthy()
    award(3, 1, "Tester", "given", 21, 120)
    expect(forge.findText("MS 51-150")).toBeTruthy()   -- 70 - 20 = 50 left
    award(4, 1, "Tester", "given", 51, 150)
    expect(forge.findText("MS 1-100")).toBeTruthy()    -- 0 left: an ordinary roll
    import("WL2;Tester;1792140000;30\n20513;ms;1;1;")
    expect(forge.findText("MS 31-130")).toBeTruthy()
    expect(#forge.errors()).toBe(0)
end)
