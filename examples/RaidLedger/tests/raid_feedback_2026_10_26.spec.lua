-- Raid feedback of 2026-10-26 (examples/RaidLedger-requirements.md): a reopened
-- corpse listed its loot again, group loot was recorded, trades were tracked,
-- open items showed in both tabs, and the disenchanter was rolled per item.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local TOME = "|cffa335ee|Hitem:21281:0:0:0:0:0:0:0:60|h[Grimoire of Shadow Bolt]|h|r"
local BOOTS = "|cffa335ee|Hitem:20514:0:0:0:0:0:0:0:60|h[Abyssal Boots]|h|r"
local BOSS = "0xF130003B6900182E"
local TRASH = "0xF130003B6A000042"

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

local function died(guid)
    forge.fire("COMBAT_LOG_EVENT_UNFILTERED", 0, "UNIT_DIED", "0x0", "", 0, guid, "Creature", 0)
end

-- The corpse popup alone offers SPÄTER WÜRFELN (FR-RL-012).
local function laterTo(name)
    forge.click("RaidLedgerMasterLootLater")
    name = (name and name ~= "") and name or UnitName("player")
    for g = 1, 5 do
        for r = 1, 5 do
            local cell = forge.frame("RaidLedgerMasterLootMember" .. g .. "_" .. r)
            if cell and cell:IsShown() and cell.fullName == name then return forge.click(cell) end
        end
    end
    error("no raid list entry for " .. name)
end

test("FR-RL-001 a corpse reopened after a hand-out lists no item twice", function()
    forge.raid({ "Tester", "Alice", "Bob" })
    forge.masterLoot({ "Tester", "Alice", "Bob" })
    forge.unit("target", { name = "Crimson Templar", guid = BOSS, dead = true, isPlayer = false })
    forge.openLoot({ { id = 20513 }, { id = 21281 }, { id = 20514 } })
    expect(forge.findText("LOOT (3)")).toBeTruthy()
    GiveMasterLoot(1, 2)
    forge.advance(0.1)
    forge.closeLoot()
    -- The client lists only what is left, from slot 1 on.
    forge.openLoot({ { id = 21281 }, { id = 20514 } })
    forge.advance(0.5, 0.25)
    expect(forge.findText("LOOT (2)")).toBeTruthy()
    forge.closeLoot()
    forge.openLoot({ { id = 21281 }, { id = 20514 } })
    forge.advance(0.5, 0.25)
    expect(forge.findText("LOOT (2)")).toBeTruthy()
    GiveMasterLoot(2, 3)                         -- the boots, from the reopened window
    expect(db().history[1].item).toBe(BOOTS)
    expect(db().history[1].recipient).toBe("Bob")
    forge.advance(0.1)
    expect(forge.findText("LOOT (1)")).toBeTruthy()
    forge.closeLoot()
    forge.slash("/ledger clear")
end)

test("FR-RL-001 an untargeted corpse keeps its name when another creature dies", function()
    forge.unit("target", false)
    died(BOSS)
    forge.unit("mouseover", { name = "Crimson Templar", guid = BOSS, dead = true, isPlayer = false })
    forge.openLoot({ { id = 20513 }, { id = 21281 } })
    forge.advance(0.5, 0.25)
    expect(forge.findText("LOOT (2)")).toBeTruthy()
    forge.closeLoot()
    forge.unit("mouseover", false)
    died(TRASH)                                  -- a trash kill before the corpse is opened again
    forge.unit("mouseover", { name = "Crimson Templar", guid = BOSS, dead = true, isPlayer = false })
    forge.openLoot({ { id = 20513 }, { id = 21281 } })
    forge.advance(0.5, 0.25)
    expect(forge.findText("LOOT (2)")).toBeTruthy()
    forge.closeLoot()
    forge.unit("mouseover", false)
    forge.slash("/ledger clear")
end)

test("FR-RL-001 two copies of one item on a corpse are both listed", function()
    forge.unit("target", { name = "Crimson Templar", guid = TRASH, dead = true, isPlayer = false })
    forge.openLoot({ { id = 21281 }, { id = 21281 } })
    forge.advance(0.5, 0.25)
    expect(forge.findText("LOOT (2)")).toBeTruthy()
    forge.closeLoot()
    forge.openLoot({ { id = 21281 }, { id = 21281 } })
    forge.advance(0.5, 0.25)
    expect(forge.findText("LOOT (2)")).toBeTruthy()
    forge.closeLoot()
    forge.unit("target", false)
    forge.slash("/ledger clear")
end)

test("FR-RL-002 an item won with group loot is not recorded", function()
    local before = table.getn(db().history)
    forge.fire("CHAT_MSG_LOOT", "Bob won: " .. TOME)
    forge.fire("CHAT_MSG_LOOT", "Bob receives loot: " .. TOME .. ".")
    forge.fire("CHAT_MSG_LOOT", "You won: " .. CREST)
    forge.fire("CHAT_MSG_LOOT", "You receive loot: " .. CREST .. ".")
    expect(table.getn(db().history)).toBe(before)
end)

test("FR-RL-003 an item the master looter keeps for the winner is the winner's award at once", function()
    forge.unit("target", { name = "Crimson Templar", guid = "0xF130003B6B000043", dead = true, isPlayer = false })
    forge.openLoot({ { id = 21281 } })
    forge.slash("/ledger start")
    forge.roll("Alice", 50)
    forge.advance(31, 0.25)
    GiveMasterLoot(1, 1)                         -- Tester keeps it to hand it over
    forge.advance(0.1)
    local record = db().history[1]
    expect(record.recipient).toBe("Alice")
    expect(record.state ~= "held").toBe(true)
    expect(record.spec).toBe("ms")
    expect(record.confirmed).toBe(true)
    expect(raidSaid("[Loot] " .. TOME .. " goes to Alice - main spec (Tester hands it over).")).toBe(true)
    forge.closeLoot()
    forge.unit("target", false)
end)

test("FR-RL-003 a completed trade changes no award", function()
    local id = db().history[1].id
    forge.trade("Bob", { TOME })
    expect(db().history[1].id).toBe(id)
    expect(db().history[1].recipient).toBe("Alice")
    expect(db().lastTrade).toBeNil()
    for _, line in ipairs(forge.chat()) do expect(string.find(line, "trade recorded", 1, true)).toBeNil() end
end)

test("FR-RL-004 an open item is listed in BEUTE only, until its roll is won", function()
    forge.slash("/ledger newraid confirm")
    forge.unit("target", { name = "Crimson Templar", guid = "0xF130003B6C000044", dead = true, isPlayer = false })
    forge.openLoot({ { id = 20514 } })
    forge.type("RaidLedgerRecipient", "Bob")
    laterTo(forge.text("RaidLedgerRecipient"))
    forge.advance(0.1)
    forge.closeLoot()
    forge.unit("target", false)
    expect(db().history[1].state).toBe("parked")
    expect(forge.findText("OPEN ITEMS (1)")).toBeTruthy()
    expect(forge.findText("AWARDS (0)")).toBeTruthy()
    forge.click("RaidLedgerTabButtonAwards")
    expect(forge.findText(BOOTS, true)).toBeNil()
    forge.click("RaidLedgerTabButtonLoot")
    forge.click("RaidLedgerItemRow2")            -- row 1 is the OPEN ITEMS heading
    forge.click("RaidLedgerStart")
    forge.roll("Alice", 77)
    forge.advance(31, 0.25)
    forge.click("RaidLedgerAward")
    expect(db().history[1].recipient).toBe("Alice")
    expect(forge.findText("OPEN ITEMS (1)")).toBeNil()
    expect(forge.findText("AWARDS (1)")).toBeTruthy()
    forge.click("RaidLedgerTabButtonAwards")
    expect(forge.findText(BOOTS, true)).toBeTruthy()
    forge.click("RaidLedgerTabButtonLoot")
end)

test("FR-RL-005 the disenchanter roll takes /rnd 100 only and names the raid's disenchanter", function()
    forge.raid({ "Tester", "Alice", "Bob", "Cara" })
    forge.click("RaidLedgerDisenchanterRoll")
    expect(raidSaid("[Loot] Disenchanter roll: /rnd 100 now, 30 seconds. The winner disenchants this raid's unwanted items.")).toBe(true)
    forge.roll("Alice", 40)
    forge.roll("Bob", 87)
    forge.roll("Cara", 300, 1, 300)
    forge.advance(31, 0.25)
    expect(db().disenchanter).toBe("Bob")
    expect(raidSaid("[Loot] Bob is the disenchanter for this raid (87).")).toBe(true)
    expect(forge.findText("LOOT (0)")).toBeTruthy()   -- the roll leaves the loot list
end)

test("FR-RL-005 DE gives an unwanted item to the disenchanter, whatever the box holds", function()
    forge.masterLoot({ "Tester", "Alice", "Bob", "Cara" })
    forge.unit("target", { name = "Crimson Templar", guid = "0xF130003B6D000045", dead = true, isPlayer = false })
    forge.openLoot({ { id = 20513 } })
    forge.slash("/ledger start")
    forge.advance(31, 0.25)                      -- nobody rolled
    forge.type("RaidLedgerRecipient", "Alice")
    forge.click("RaidLedgerDisenchant")
    expect(forge.awards()[table.getn(forge.awards())].candidate).toBe("Bob")
    forge.advance(0.1)
    local record = db().history[1]
    expect(record.item).toBe(CREST)
    expect(record.state).toBe("disenchanted")
    expect(record.recipient).toBe("Bob")
    expect(record.spec).toBeNil()
    expect(raidSaid("[Loot] " .. CREST .. " will be disenchanted (Bob).")).toBe(true)
    forge.closeLoot()
    forge.unit("target", false)
end)

test("FR-RL-005 NEW RAID forgets the disenchanter", function()
    forge.slash("/ledger newraid confirm")
    expect(db().disenchanter).toBeNil()
end)
