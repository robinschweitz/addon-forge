-- Items that wait before they are rolled: parked with a raider (unique items),
-- kept by the master looter, rolled later from the loot list (the only place
-- they are listed until they are won, raid of 2026-10-26), and shared with
-- wishlist addons as open items.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local TOME = "|cffa335ee|Hitem:21281:0:0:0:0:0:0:0:60|h[Grimoire of Shadow Bolt]|h|r"
local BOOTS = "|cffa335ee|Hitem:20514:0:0:0:0:0:0:0:60|h[Abyssal Boots]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.item(21281, { name = "Grimoire of Shadow Bolt", link = TOME, quality = 4 })
    forge.item(20514, { name = "Abyssal Boots", link = BOOTS, quality = 4 })
end)

local function db() return forge.saved("RaidLedgerDB") end

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
    forge.type("RaidLedgerRecipient", "Bob")
    forge.click("RaidLedgerPark")
    expect(forge.awards()[1].candidate).toBe("Bob")
    local record = db().history[1]
    expect(record.state).toBe("parked")
    expect(record.recipient).toBe("Bob")
    expect(record.spec).toBeNil()
    forge.advance(0.1)
    expect(record.confirmed).toBe(true)
    expect(raidSaid("[Loot] " .. CREST .. " is parked with Bob until it is rolled.")).toBe(true)
    expect(forge.findText("LOOT (1)  |  1 OPEN")).toBeTruthy()
end)

test("PARK without a name keeps the item with the master looter", function()
    expect(forge.text("RaidLedgerItemRow1")).toBe(TOME)
    forge.click("RaidLedgerItemRow1")
    forge.click("RaidLedgerPark")
    forge.advance(0.1)
    local record = db().history[1]
    expect(record.recipient).toBe("Tester")
    expect(record.state).toBe("parked")
    forge.closeLoot()
end)

test("parked items do not count in anyone's tally", function()
    forge.slash("/ledger tally")
    expect(forge.chat()).toContain("RaidLedger: no items counted this raid yet.")
end)

test("open items are not in VERGABEN; one is rolled from BEUTE like any other", function()
    forge.click("RaidLedgerTabButtonAwards")
    expect(forge.findText("AWARDS (0)")).toBeTruthy()
    expect(forge.findText("#1  ", true)).toBeNil()
    forge.click("RaidLedgerTabButtonLoot")
    expect(forge.text("RaidLedgerItemRow2")).toBe(CREST)   -- under OPEN ITEMS, parked with Bob
    forge.click("RaidLedgerItemRow2")
    forge.click("RaidLedgerStart")
    expect(forge.findText("LOOT (1)  |  1 OPEN")).toBeTruthy()    -- the roll shows in BEUTE; the tome is still open
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
    forge.slash("/ledger tally")
    expect(forge.chat()).toContain("RaidLedger: Cara: 1 main spec, 0 off spec")
end)

test("a later roll on an item the master looter holds goes to the winner at once", function()
    forge.click("RaidLedgerTabButtonLoot")
    expect(forge.text("RaidLedgerItemRow2")).toBe(TOME)    -- kept by Tester
    forge.click("RaidLedgerItemRow2")
    forge.click("RaidLedgerStart")
    forge.roll("Alice", 70, 1, 99)
    forge.advance(31, 0.25)
    forge.clickText("RECORD AWARD")
    local record = db().history[1]
    expect(record.id).toBe(2)
    expect(record.recipient).toBe("Alice")
    expect(record.holder).toBe("Tester")
    expect(record.state).toBe("manual")
    expect(record.winner).toBe("Alice")
    expect(record.spec).toBe("os")
    expect(raidSaid("[Loot] " .. TOME .. " goes to Alice - off spec (Tester hands it over).")).toBe(true)
end)

test("an item kept without a roll is open, listed in BEUTE only", function()
    forge.openLoot({ { id = 20514 } })
    GiveMasterLoot(1, 1)                               -- from the default menu, no roll
    forge.advance(0.1)
    forge.closeLoot()
    local record = db().history[1]
    expect(record.state).toBe("held")
    expect(forge.findText("OPEN ITEMS (1)")).toBeTruthy()
    forge.click("RaidLedgerTabButtonAwards")
    expect(forge.findText("AWARDS (2)")).toBeTruthy()
    expect(forge.findText("#3  ", true)).toBeNil()
end)

test("a recorded award can be marked as parked with its holder", function()
    forge.click(forge.findText("#2  ", true))           -- the tome, given to Alice
    expect(forge.text("RaidLedgerAwardPark")).toBe("PARK")
    forge.type("RaidLedgerAwardRecipient", "Bob")
    forge.click("RaidLedgerAwardPark")
    local record = db().history[2]
    expect(record.state).toBe("parked")
    expect(record.recipient).toBe("Bob")
    expect(record.winner).toBeNil()
    expect(record.spec).toBeNil()
    expect(forge.findText("#2  ", true)).toBeNil()          -- open now: it moved to BEUTE
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
end)

test("open corpse items are shared with their roll status", function()
    forge.click("RaidLedgerTabButtonLoot")
    forge.openLoot({ { id = 20513 }, { id = 20514 } })
    forge.advance(3, 0.25)               -- the list queues behind award messages
    expect(lastOpenList()).toBe("20514:o:c:,20513:o:c:")
    forge.slash("/ledger start")
    forge.advance(3, 0.25)               -- the list queues behind award messages
    expect(lastOpenList()).toBe("20514:o:c:,20513:r:c:")
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
    forge.closeLoot()
end)
