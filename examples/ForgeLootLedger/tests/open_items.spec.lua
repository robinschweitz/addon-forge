-- Items that wait before they are rolled: parked with a raider (unique items),
-- kept by the master looter, rolled later from the award list, and shared
-- with wishlist addons as open items.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local TOME = "|cffa335ee|Hitem:21281:0:0:0:0:0:0:0:60|h[Grimoire of Shadow Bolt]|h|r"
local BOOTS = "|cffa335ee|Hitem:20514:0:0:0:0:0:0:0:60|h[Abyssal Boots]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.item(21281, { name = "Grimoire of Shadow Bolt", link = TOME, quality = 4 })
    forge.item(20514, { name = "Abyssal Boots", link = BOOTS, quality = 4 })
end)

local function db() return forge.saved("ForgeLootLedgerDB") end

local function raidSaid(text)
    for _, m in ipairs(forge.sent()) do
        if m.message == text then return true end
    end
    return false
end

local function lastOpenList()
    local list
    for _, m in ipairs(forge.addonMessages()) do
        local items = string.match(m.message, "^O;[^;]*;Tester;(.*)$")
        if items then list = items end
    end
    return list
end

test("PARK hands loot to a raider to hold until it is rolled", function()
    forge.raid({ "Tester", "Alice", "Bob", "Cara" })
    forge.masterLoot({ "Tester", "Alice", "Bob", "Cara" })
    forge.openLoot({ { id = 20513 }, { id = 21281 } })
    forge.clickText("Bob")
    forge.click("ForgeLootLedgerPark")
    expect(forge.awards()[1].candidate).toBe("Bob")
    local record = db().history[1]
    expect(record.state).toBe("parked")
    expect(record.recipient).toBe("Bob")
    expect(record.spec).toBeNil()
    forge.advance(0.1)
    expect(record.confirmed).toBe(true)
    expect(raidSaid("[Loot] " .. CREST .. " is parked with Bob until it is rolled.")).toBe(true)
    expect(forge.findText("OPEN")).toBeTruthy()
end)

test("PARK without a name keeps the item with the master looter", function()
    expect(forge.text("ForgeLootLedgerRow1")).toBe(TOME)
    forge.click("ForgeLootLedgerRow1")
    forge.click("ForgeLootLedgerPark")
    forge.advance(0.1)
    local record = db().history[1]
    expect(record.recipient).toBe("Tester")
    expect(record.state).toBe("parked")
    forge.closeLoot()
end)

test("parked items do not count in anyone's tally", function()
    forge.slash("/forgeloot tally")
    expect(forge.chat()).toContain("ForgeLootLedger: no items counted this raid yet.")
end)

test("an open award reads ROLL, and its roll runs like any other", function()
    forge.click(forge.findText("#1  ", true))           -- the crest, parked with Bob
    expect(forge.findText("ROLL")).toBeTruthy()
    forge.click("ForgeLootLedgerPark")
    expect(forge.findText("MASTER LOOT ITEMS")).toBeTruthy()
    expect(raidSaid("[Loot] " .. CREST .. " - /rnd now! 30 seconds. /rnd 100 main spec (enhanced: 1+X to 100+X, X up to 50), /rnd 99 off spec.")).toBe(true)
    forge.advance(3, 0.25)               -- the list queues behind award messages
    expect(lastOpenList()).toBe("20513:r:a1:")
    forge.roll("Cara", 80)
    forge.roll("Alice", 30)
    forge.advance(31, 0.25)
    expect(lastOpenList()).toBe("20513:w:a1:Cara")
end)

test("a later roll on an item another raider holds goes to the winner, from the holder", function()
    forge.clickText("RECORD AWARD")
    local record = db().history[2]
    expect(record.id).toBe(1)
    expect(record.recipient).toBe("Cara")
    expect(record.state).toBe("manual")
    expect(record.holder).toBe("Bob")
    expect(record.spec).toBe("ms")
    expect(record.roll).toBe(80)
    expect(#record.rollLog).toBe(2)
    expect(raidSaid("[Loot] " .. CREST .. " goes to Cara - main spec (Bob hands it over).")).toBe(true)
    forge.advance(3, 0.25)               -- the list queues behind award messages
    expect(lastOpenList()).toBe("")
    forge.slash("/forgeloot tally")
    expect(forge.chat()).toContain("ForgeLootLedger: Cara: 1 main spec, 0 off spec")
end)

test("a later roll on an item the master looter holds waits for the trade to the winner", function()
    forge.click(forge.findText("#2  ", true))           -- the tome, kept by Tester
    forge.click("ForgeLootLedgerPark")
    forge.roll("Alice", 70, 1, 99)
    forge.advance(31, 0.25)
    forge.clickText("RECORD AWARD")
    local record = db().history[1]
    expect(record.id).toBe(2)
    expect(record.recipient).toBe("Tester")
    expect(record.state).toBe("held")
    expect(record.winner).toBe("Alice")
    expect(record.spec).toBe("os")
    expect(raidSaid("[Loot] " .. TOME .. " goes to Alice - off spec (with Tester until traded).")).toBe(true)
    forge.trade("Alice", { TOME })
    expect(record.recipient).toBe("Alice")
    expect(record.state).toBe("given")
end)

test("an item kept without a roll is open, and trading it parks it with the partner", function()
    forge.openLoot({ { id = 20514 } })
    GiveMasterLoot(1, 1)                               -- from the default menu, no roll
    forge.advance(0.1)
    forge.closeLoot()
    local record = db().history[1]
    expect(record.state).toBe("held")
    expect(forge.findText("OPEN")).toBeTruthy()
    forge.trade("Dora", { BOOTS })
    expect(record.recipient).toBe("Dora")
    expect(record.state).toBe("parked")
    expect(raidSaid("[Loot] " .. BOOTS .. " is parked with Dora until it is rolled.")).toBe(true)
end)

test("a recorded award can be marked as parked with its holder", function()
    forge.click(forge.findText("#2  ", true))           -- the tome, given to Alice
    expect(forge.findText("PARK")).toBeTruthy()
    forge.clickText("Bob")
    forge.click("ForgeLootLedgerPark")
    local record = db().history[2]
    expect(record.state).toBe("parked")
    expect(record.recipient).toBe("Bob")
    expect(record.winner).toBeNil()
    expect(record.spec).toBeNil()
    expect(forge.layoutIssues("ForgeLootLedgerFrame")).toEqual({})
end)

test("open corpse items are shared with their roll status", function()
    forge.openLoot({ { id = 20513 }, { id = 20514 } })
    forge.advance(3, 0.25)               -- the list queues behind award messages
    expect(lastOpenList()).toBe("20514:o:c:,20513:o:c:")
    forge.slash("/forgeloot start")
    forge.advance(3, 0.25)               -- the list queues behind award messages
    expect(lastOpenList()).toBe("20514:o:c:,20513:r:c:")
    expect(forge.layoutIssues("ForgeLootLedgerFrame")).toEqual({})
    forge.closeLoot()
end)

test("a trade moves the copy the partner won before an older open copy", function()
    forge.slash("/forgeloot newraid confirm")
    forge.openLoot({ { id = 21281 } })
    GiveMasterLoot(1, 1)                               -- older copy: kept, no roll (open)
    forge.advance(0.1)
    forge.closeLoot()
    forge.slash("/forgeloot clear")
    forge.unit("target", { name = "Templar", guid = "0xF130003B69000999", dead = true, isPlayer = false })
    forge.openLoot({ { id = 21281 } })
    forge.slash("/forgeloot start")
    forge.roll("Alice", 40)
    forge.advance(31, 0.25)
    GiveMasterLoot(1, 1)                               -- newer copy: kept for the winner, Alice
    forge.advance(0.1)
    forge.closeLoot()
    local newer, older = db().history[1], db().history[2]
    expect(newer.winner).toBe("Alice")
    expect(older.winner).toBeNil()
    forge.trade("Alice", { TOME })
    expect(newer.recipient).toBe("Alice")
    expect(newer.state).toBe("given")
    expect(older.recipient).toBe("Tester")
    expect(older.state).toBe("held")
end)
