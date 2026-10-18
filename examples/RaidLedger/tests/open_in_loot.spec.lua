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
local function row(i) return forge.frame("RaidLedgerRow" .. i) end

test("parked and kept items stay in the loot list as OPEN; DE and bank items do not", function()
    forge.raid({ "Tester", "Alice", "Bob", "Cara" })
    forge.masterLoot({ "Tester", "Alice", "Bob", "Cara" })
    forge.openLoot({ { id = 20513 }, { id = 21281 }, { id = 20514 } })
    forge.clickText("Bob")
    forge.click("RaidLedgerPark")                       -- crest parked with Bob
    forge.click("RaidLedgerRow1")
    forge.clickText("Cara")
    forge.click("RaidLedgerBank")                       -- tome to the bank character
    forge.click("RaidLedgerRow1")
    forge.click("RaidLedgerDisenchant")                 -- boots disenchanted by Tester
    forge.advance(0.1)
    forge.closeLoot()
    expect(db().history[1].state).toBe("disenchanted")
    expect(db().history[2].state).toBe("bank")
    expect(db().history[3].state).toBe("parked")
    expect(forge.text("RaidLedgerRow1")).toBe(CREST)
    expect(forge.text(row(1).holder)).toBe("with Bob")
    expect(forge.text(row(1).count)).toBe("OPEN")
    expect(row(2):IsShown()).toBe(false)               -- not the bank or DE items
    expect(forge.text(forge.findText("MASTER LOOT ITEMS", true))).toBe("MASTER LOOT ITEMS  (1 OPEN)")
    expect(forge.findText("Open the master loot window", true)).toBeFalsy()
end)

test("an item kept by the master looter without a roll is open too, after the loot items", function()
    forge.openLoot({ { id = 20515 } })
    GiveMasterLoot(1, 1)                                -- from the default menu, no roll
    forge.advance(0.1)
    expect(db().history[1].state).toBe("held")
    forge.openLoot({ { id = 20514 } })                 -- new loot comes first
    expect(forge.text("RaidLedgerRow1")).toBe(BOOTS)
    expect(forge.text("RaidLedgerRow2")).toBe(CREST)
    expect(forge.text("RaidLedgerRow3")).toBe(RING)
    expect(forge.text(row(3).holder)).toBe("with Tester")
    expect(forge.text(row(3).count)).toBe("OPEN")
    forge.click("RaidLedgerRow1")
    forge.click("RaidLedgerDisenchant")
    forge.advance(0.1)
    forge.closeLoot()
    expect(forge.text("RaidLedgerRow1")).toBe(CREST)
end)

test("clicking an open item selects its award: ROLL, and the list stays", function()
    forge.click("RaidLedgerRow1")
    expect(forge.findText("ROLL")).toBeTruthy()
    expect(forge.text(forge.frame("RaidLedgerRecipient"))).toBe("Bob")
    expect(forge.text(forge.findText("MASTER LOOT ITEMS", true))).toBe("MASTER LOOT ITEMS  (2 OPEN)")
    expect(forge.text("RaidLedgerRow1")).toBe(CREST)
end)

test("a later roll lists the item once, as a roll; the award ends its OPEN row", function()
    forge.click("RaidLedgerPark")                       -- reads ROLL
    expect(forge.text("RaidLedgerRow1")).toBe(CREST)
    expect(forge.text(row(1).count)).toBe("0 ROLLS")
    expect(forge.text(row(1).holder)).toBe("")         -- a roll row has no holder column
    expect(forge.text("RaidLedgerRow2")).toBe(RING)
    expect(forge.text(row(2).count)).toBe("OPEN")
    expect(row(3):IsShown()).toBe(false)
    forge.roll("Alice", 80)
    forge.advance(31, 0.25)
    forge.clickText("RECORD AWARD")
    forge.advance(0.1)
    expect(forge.text("RaidLedgerRow1")).toBe(RING)
    expect(forge.text(forge.findText("MASTER LOOT ITEMS", true))).toBe("MASTER LOOT ITEMS  (1 OPEN)")
    expect(#forge.errors()).toBe(0)
end)

test("many open items leave room for the selected roll's log", function()
    local drops = {}
    for id = 30001, 30007 do table.insert(drops, { id = id }) end
    forge.openLoot(drops)
    for _ = 1, 7 do
        forge.click("RaidLedgerRow1")
        forge.click("RaidLedgerPark")
        forge.advance(0.1)
    end
    forge.closeLoot()
    expect(forge.findText("MASTER LOOT ITEMS  (8 OPEN)")).toBeTruthy()
    expect(forge.frame("RaidLedgerRow8"):IsShown()).toBe(true)   -- eight open rows fit while nothing rolls
    forge.openLoot({ { id = 20514 } })
    forge.slash("/ledger start")
    for _, name in ipairs({ "Alice", "Bob", "Cara", "Tester" }) do forge.roll(name, 50) end
    forge.advance(1, 0.25)
    expect(forge.text("RaidLedgerRow1")).toBe(BOOTS)
    expect(forge.text(forge.frame("RaidLedgerRow5").count)).toBe("OPEN")
    expect(forge.text("RaidLedgerRow6")).toBe("ROLLS")             -- 4 open rows, then all four rolls
    expect(forge.text("RaidLedgerRow10")).toContain("Alice")
    expect(forge.findText("MASTER LOOT ITEMS  (8 OPEN)")).toBeTruthy()
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
end)
