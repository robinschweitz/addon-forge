-- Open items (parked with a raider, or kept without a roll) still have to be
-- rolled, so they stay in the master loot list, marked OPEN, after the loot
-- window closed: the master looter cannot overlook them. DE and guild-bank
-- items are handed out for good and do not show there.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local TOME = "|cffa335ee|Hitem:21281:0:0:0:0:0:0:0:60|h[Grimoire of Shadow Bolt]|h|r"
local BOOTS = "|cffa335ee|Hitem:20514:0:0:0:0:0:0:0:60|h[Abyssal Boots]|h|r"
local RING = "|cffa335ee|Hitem:20515:0:0:0:0:0:0:0:60|h[Abyssal Ring]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.item(21281, { name = "Grimoire of Shadow Bolt", link = TOME, quality = 4 })
    forge.item(20514, { name = "Abyssal Boots", link = BOOTS, quality = 4 })
    forge.item(20515, { name = "Abyssal Ring", link = RING, quality = 4 })
    for id = 30001, 30007 do
        forge.item(id, { name = "Relic " .. id, link = "|cffa335ee|Hitem:" .. id .. ":0:0:0:0:0:0:0:80|h[Relic " .. id .. "]|h|r", quality = 4 })
    end
end)

local function db() return forge.saved("RaidLedgerDB") end
local function row(i) return forge.frame("RaidLedgerItemRow" .. i) end
local function status(i) return forge.text(row(i).columns[1]) end
local function heading() return forge.text(forge.frame("RaidLedgerRollPane").heading) end

-- SPÄTER WÜRFELN asks who keeps the item (FR-RL-012): the name in the box,
-- else the player, picked from the raid list.
local function laterTo(name)
    forge.click("RaidLedgerPark")
    name = (name and name ~= "") and name or UnitName("player")
    for g = 1, 5 do
        for r = 1, 5 do
            local cell = forge.frame("RaidLedgerMember" .. g .. "_" .. r)
            if cell and cell:IsShown() and cell.fullName == name then return forge.click(cell) end
        end
    end
    error("no raid list entry for " .. name)
end

test("parked and kept items stay in the loot list as OPEN; DE and bank items do not", function()
    forge.raid({ "Tester", "Alice", "Bob", "Cara" })
    forge.masterLoot({ "Tester", "Alice", "Bob", "Cara" })
    forge.openLoot({ { id = 20513 }, { id = 21281 }, { id = 20514 } })
    forge.type("RaidLedgerRecipient", "Bob")
    laterTo(forge.text("RaidLedgerRecipient"))                       -- crest parked with Bob
    forge.click("RaidLedgerItemRow1")
    forge.type("RaidLedgerRecipient", "Cara")
    forge.click("RaidLedgerBank")                       -- tome to the bank character
    forge.click("RaidLedgerItemRow1")
    forge.click("RaidLedgerDisenchant")                 -- boots disenchanted by Tester
    forge.advance(0.1)
    forge.closeLoot()
    expect(db().history[1].state).toBe("disenchanted")
    expect(db().history[2].state).toBe("bank")
    expect(db().history[3].state).toBe("parked")
    -- The open items have their own section under the loot.
    expect(forge.text("RaidLedgerItemRow1")).toBe("OPEN ITEMS (1)")
    expect(forge.text("RaidLedgerItemRow2")).toBe(CREST)
    expect(status(2)).toBe("with Bob")
    expect(row(3):IsShown()).toBe(false)               -- not the bank or DE items
    expect(heading()).toBe("LOOT (0)  |  1 OPEN")
    expect(forge.findText("Open the master loot window", true)).toBeFalsy()
end)

test("an item kept by the master looter without a roll is open too, after the loot items", function()
    forge.openLoot({ { id = 20515 } })
    GiveMasterLoot(1, 1)                                -- from the default menu, no roll
    forge.advance(0.1)
    expect(db().history[1].state).toBe("held")
    forge.openLoot({ { id = 20514 } })                 -- new loot comes first
    expect(forge.text("RaidLedgerItemRow1")).toBe(BOOTS)
    expect(forge.text("RaidLedgerItemRow2")).toBe("OPEN ITEMS (2)")
    expect(forge.text("RaidLedgerItemRow3")).toBe(CREST)
    expect(forge.text("RaidLedgerItemRow4")).toBe(RING)
    expect(status(4)).toBe("with Tester")
    forge.click("RaidLedgerItemRow1")
    forge.click("RaidLedgerDisenchant")
    forge.advance(0.1)
    forge.closeLoot()
    expect(forge.text("RaidLedgerItemRow2")).toBe(CREST)
end)

test("clicking an open item selects it: ROLL starts its roll, the list stays", function()
    forge.click("RaidLedgerItemRow2")
    expect(forge.text("RaidLedgerItem")).toBe(CREST)
    expect(forge.text("RaidLedgerRollDetail")).toContain("Bob holds it")
    expect(forge.frame("RaidLedgerStart"):IsEnabled()).toBeTruthy()
    expect(forge.frame("RaidLedgerAward"):IsEnabled()).toBeFalsy()   -- an open item is rolled first
    expect(heading()).toBe("LOOT (0)  |  2 OPEN")
end)

test("a later roll lists the item once, as a roll; the award ends its OPEN row", function()
    forge.click("RaidLedgerStart")
    expect(forge.text("RaidLedgerItemRow1")).toBe(CREST)
    expect(status(1)).toBe("30s LEFT")
    expect(forge.text("RaidLedgerItemRow2")).toBe("OPEN ITEMS (1)")
    expect(forge.text("RaidLedgerItemRow3")).toBe(RING)
    expect(row(4):IsShown()).toBe(false)
    forge.roll("Alice", 80)
    forge.advance(31, 0.25)
    expect(forge.text("RaidLedgerRecipient")).toBe("Alice")
    forge.click("RaidLedgerAward")
    forge.advance(0.1)
    expect(forge.text("RaidLedgerItemRow2")).toBe(RING)
    expect(heading()).toBe("LOOT (0)  |  1 OPEN")
    expect(#forge.errors()).toBe(0)
end)

test("many open items and a long roll both stay readable", function()
    local drops = {}
    for id = 30001, 30007 do table.insert(drops, { id = id }) end
    forge.openLoot(drops)
    for _ = 1, 7 do
        forge.click("RaidLedgerItemRow1")
        laterTo(forge.text("RaidLedgerRecipient"))
        forge.advance(0.1)
    end
    forge.closeLoot()
    expect(heading()).toBe("LOOT (0)  |  8 OPEN")
    expect(row(9):IsShown()).toBe(true)                -- the heading and all eight open items
    forge.openLoot({ { id = 20514 } })
    forge.click("RaidLedgerItemRow1")
    forge.slash("/ledger start")
    for _, name in ipairs({ "Alice", "Bob", "Cara", "Tester" }) do forge.roll(name, 50) end
    forge.advance(1, 0.25)
    expect(forge.text("RaidLedgerItemRow1")).toBe(BOOTS)
    expect(row(10):IsShown()).toBe(true)               -- the open items stay listed during the roll
    for i = 1, 4 do expect(forge.frame("RaidLedgerRollLine" .. i):IsShown()).toBe(true) end
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
end)
