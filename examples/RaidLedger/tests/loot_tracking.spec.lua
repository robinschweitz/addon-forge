-- Loot tracking taken over from RaidSync: real master-loot recipients, items the
-- master looter keeps for a winner, the loot threshold and drop sources.
local CREST = "|cff1eff00|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local TOME = "|cffa335ee|Hitem:21281:0:0:0:0:0:0:0:60|h[Grimoire of Shadow Bolt]|h|r"
local TRASH = "|cff9d9d9d|Hitem:3300:0:0:0:0:0:0:0:60|h[Rabbit's Foot]|h|r"
local TEMPLAR = "0xF130003B6900182E"   -- creature 15209, as seen live

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 2 })
    forge.item(21281, { name = "Grimoire of Shadow Bolt", link = TOME, quality = 4 })
    forge.item(3300, { name = "Rabbit's Foot", link = TRASH, quality = 0 })
end)

local function db() return forge.saved("RaidLedgerDB") end

local function lootTemplar(items)
    forge.unit("target", { name = "Crimson Templar", guid = TEMPLAR, dead = true, isPlayer = false })
    forge.openLoot(items)
end

test("the award button hands the item to the roll winner and records the real recipient", function()
    forge.party({ "Alice", "Bob" })
    forge.masterLoot({ "Tester", "Alice", "Bob" })
    lootTemplar({ { id = 20513 } })
    forge.slash("/ledger start")
    forge.roll("Alice", 30)
    forge.roll("Bob", 88)
    forge.advance(31, 0.25)
    forge.click("RaidLedgerAward")
    expect(forge.awards()[1].slot).toBe(1)
    expect(forge.awards()[1].candidate).toBe("Bob")
    expect(db().history[1]).toBeNil()
    forge.advance(0.1)
    local record = db().history[1]
    expect(record.recipient).toBe("Bob")
    expect(record.state).toBe("given")
    expect(record.confirmed).toBe(true)
    expect(record.itemID).toBe(20513)
    expect(record.npc).toBe(15209)
    expect(record.roll).toBe(88)
    expect(record.rolls).toBe(2)
    forge.click("RaidLedgerTabButtonAwards")
    expect(forge.findText("GIVEN")).toBeTruthy()
end)

test("the server's loot message confirms the handout", function()
    forge.advance(0.1)
    expect(db().history[1].confirmed).toBe(true)
    expect(forge.findText("GIVEN")).toBeTruthy()
    expect(forge.findText("Award #1 confirmed: Bob received the item.")).toBeTruthy()
    forge.click("RaidLedgerTabButtonLoot")
    expect(forge.findText(CREST)).toBeNil()     -- gone from the active list, not re-added
    forge.closeLoot()
end)

test("handouts from the default master-loot menu are recorded, and a reopened corpse lists items once", function()
    lootTemplar({ { id = 21281 } })
    forge.closeLoot()
    lootTemplar({ { id = 21281 } })             -- the same corpse again
    GiveMasterLoot(1, 2)                        -- Alice, as the Blizzard menu would
    forge.advance(0.1)
    expect(db().history[1].recipient).toBe("Alice")
    expect(db().history[1].itemID).toBe(21281)
    expect(table.getn(db().history)).toBe(2)
    expect(forge.findText(TOME)).toBeNil()      -- no duplicate row was left behind
    expect(db().history[1].confirmed).toBe(true)
    forge.closeLoot()
end)

test("a recipient who is no master-loot candidate is refused, not recorded", function()
    forge.masterLoot({ "Tester", "Alice" })     -- Bob is out of range
    lootTemplar({ { id = 20513, link = CREST } })
    forge.slash("/ledger clear")             -- also forgets the source, so the crest is new
    forge.advance(0.25, 0.25)
    forge.type("RaidLedgerRecipient", "Bob")
    forge.click("RaidLedgerAward")
    expect(table.getn(forge.awards())).toBe(2)
    expect(table.getn(db().history)).toBe(2)
    expect(forge.findText("Bob cannot receive this item (not a master-loot candidate).")).toBeTruthy()
    forge.closeLoot()
    forge.slash("/ledger clear")
end)

test("items below the loot threshold get no roll row", function()
    forge.openLoot({ { id = 3300 }, { id = 21281 } })
    expect(forge.findText(TRASH)).toBeNil()
    expect(forge.findText(TOME)).toBeTruthy()
    forge.closeLoot()
    forge.slash("/ledger clear")
end)

test("chest loot takes its source from the latest creature death", function()
    forge.unit("target", false)
    forge.fire("COMBAT_LOG_EVENT_UNFILTERED", 0, "UNIT_DIED", "0x0", "", 0, "0xF13000700D000042", "Boss", 0)
    forge.masterLoot({ "Tester", "Alice", "Bob" })
    forge.openLoot({ { id = 21281 } })
    GiveMasterLoot(1, 3)
    forge.advance(0.1)
    expect(db().history[1].npc).toBe(0x700D)
    forge.closeLoot()
end)

test("an item given to yourself for the roll winner is the winner's award (no trade tracking)", function()
    lootTemplar({ { id = 21281 } })
    forge.slash("/ledger clear")
    forge.advance(0.25, 0.25)
    forge.slash("/ledger start")
    forge.roll("Alice", 50)
    forge.advance(31, 0.25)
    GiveMasterLoot(1, 1)                        -- Tester keeps it for the winner, Alice
    forge.advance(0.1)
    local record = db().history[1]
    expect(record.recipient).toBe("Alice")
    expect(record.holder).toBe("Tester")
    expect(record.state).toBe("given")
    expect(record.confirmed).toBe(true)         -- by Tester's own loot line
    forge.closeLoot()
    forge.trade("Bob", { TOME })
    expect(db().history[1].recipient).toBe("Alice")
end)
