-- Members' wishlists (shared by ForgeLootWishlist) in the raid lead's ledger:
-- each drop shows how many wishlists name it, rollers show their rank, and the
-- tooltip names who wants it.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local TOME = "|cffa335ee|Hitem:21281:0:0:0:0:0:0:0:60|h[Grimoire of Shadow Bolt]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.item(21281, { name = "Grimoire of Shadow Bolt", link = TOME, quality = 4 })
end)

local function wish(sender, message)
    forge.fire("CHAT_MSG_ADDON", "FLLedger", message, "RAID", sender)
end

local function tooltipLines()
    return (forge.tooltip())
end

-- rowOf finds the loot row of an item (rows are not in drop order).
local function rowOf(link)
    for i = 1, 3 do
        local row = _G["ForgeLootLedgerRow" .. i]
        if forge.text(row) == link then return row end
    end
end

test("without any shared wishlist the rows show no WL count", function()
    forge.raid({ "Tester", "Alice", "Bob", "Cara" })
    forge.masterLoot({ "Tester", "Alice", "Bob", "Cara" })
    forge.openLoot({ { id = 20513 }, { id = 21281 } })
    expect(forge.findText("WL 0")).toBeNil()
end)

test("shared wishlists count per drop; WL 0 flags loot nobody listed", function()
    wish("Bob", "W;1792130000;1;1;20513:m:0:1,30000:m:0:2")
    wish("Alice", "W;1792130001;1;2;30001:m:0:1")
    wish("Alice", "W;1792130001;2;2;20513:o:0:4")
    expect(forge.findText("WL 2")).toBeTruthy()      -- the crest
    expect(forge.findText("WL 0")).toBeTruthy()      -- the tome
end)

test("the tooltip names who wants the drop, main spec first", function()
    forge.hover(rowOf(CREST))
    local lines = tooltipLines()
    expect(lines).toContain("On 2 wishlists:")
    local bob, alice
    for i, line in ipairs(lines) do
        if line == "  Bob - main spec, #1" then bob = i end
        if line == "  Alice - off spec, #4" then alice = i end
    end
    expect(bob ~= nil and alice ~= nil and bob < alice).toBe(true)
    forge.hover(rowOf(TOME))
    expect(tooltipLines()).toContain("On nobody's wishlist.")
end)

test("a new list from the same member replaces the old one", function()
    wish("Bob", "W;1792139999;1;1;")
    expect(forge.findText("WL 1")).toBeTruthy()
end)

test("rollers who listed the item show their wishlist rank", function()
    forge.click(rowOf(CREST))
    forge.slash("/forgeloot start")
    forge.roll("Alice", 60, 1, 99)
    forge.roll("Cara", 40)
    forge.advance(31, 0.25)
    forge.clickText("GIVE + RECORD")
    forge.advance(0.1)
    forge.click(forge.findText("#1  ", true))
    expect(forge.findText("Alice  (OS, 0 items)  [WL #4]")).toBeTruthy()
    expect(forge.findText("Cara  - won  (MS, 0 items)")).toBeTruthy()
end)

test("the ledger asks for wishlists when the raid grows", function()
    local function asks()
        local n = 0
        for _, m in ipairs(forge.addonMessages()) do if m.message == "WQ;Tester" then n = n + 1 end end
        return n
    end
    local before = asks()
    forge.raid({ "Tester", "Alice", "Bob", "Cara", "Dora" })
    forge.advance(6, 0.25)
    expect(asks()).toBe(before + 1)
    expect(#forge.errors()).toBe(0)
end)
