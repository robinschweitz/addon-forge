-- FR-RL-014: master loot opens a compact assignment popup, not the full ledger
-- or Blizzard's right-click dropdown.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local TOME = "|cffa335ee|Hitem:21281:0:0:0:0:0:0:0:60|h[Grimoire]|h|r"
local BOOTS = "|cffa335ee|Hitem:20514:0:0:0:0:0:0:0:60|h[Abyssal Boots]|h|r"
local RING = "|cffa335ee|Hitem:20515:0:0:0:0:0:0:0:60|h[Abyssal Ring]|h|r"

before_load(function()
    forge.locale("deDE", { RANDOM_ROLL_RESULT = "%1$s würfelt. Ergebnis: %2$d (%3$d-%4$d)" })
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.item(21281, { name = "Grimoire", link = TOME, quality = 4 })
    forge.item(20514, { name = "Abyssal Boots", link = BOOTS, quality = 4 })
    forge.item(20515, { name = "Abyssal Ring", link = RING, quality = 4 })
    for id = 30001, 30010 do
        forge.item(id, { name = "Relic " .. id,
            link = "|cffa335ee|Hitem:" .. id .. ":0:0:0:0:0:0:0:80|h[Relic " .. id .. "]|h|r", quality = 4 })
    end
end)

local function latestAward()
    return forge.saved("RaidLedgerDB").history[1]
end

test("FR-RL-014 master loot opens a compact assignment popup and records its actions", function()
    local names = { "Tester", "Alice", "Bob" }
    forge.raid(names)
    forge.masterLoot(names)
    forge.unit("target", { name = "Templer", guid = "0xF130003B69000114", dead = true, isPlayer = false })
    forge.slash("/ledger")
    expect("RaidLedgerFrame").toBeHidden()

    forge.openLoot({ { id = 20513 } })
    expect("RaidLedgerMasterLoot").toBeShown()
    expect("RaidLedgerFrame").toBeHidden()
    expect(forge.findText(CREST)).toBeTruthy()
    expect("RaidLedgerMasterLootRoll").toBeShown()
    expect("RaidLedgerMasterLootGive").toBeShown()
    expect("RaidLedgerMasterLootLater").toBeShown()
    expect(forge.text("RaidLedgerMasterLootGive")).toBe("ZUWEISEN")
    expect(forge.frame("RaidLedgerMasterLootDisenchant")).toBeNil()
    expect(forge.frame("RaidLedgerMasterLootBank")).toBeNil()
    expect(forge.frame("RaidLedgerPark")).toBeNil()
    expect(forge.rect("RaidLedgerMasterLoot").height < 160).toBe(true)
    local before = forge.rect("RaidLedgerMasterLoot")
    forge.drag("RaidLedgerMasterLoot", 37, -22)
    forge.advance(0.1)
    local after = forge.rect("RaidLedgerMasterLoot")
    expect(after.left).toBe(before.left + 37)
    expect(after.top).toBe(before.top - 22)
    forge.sketch("master-loot-popup", "RaidLedgerMasterLoot")

    forge.click("RaidLedgerMasterLootLater")
    expect("RaidLedgerMasterLootMembers").toBeShown()
    forge.click("RaidLedgerMasterLootMember1_2")
    forge.advance(0.1)
    expect(latestAward().state).toBe("parked")
    expect(latestAward().recipient).toBe("Alice")
    expect("RaidLedgerMasterLoot").toBeHidden()

    forge.closeLoot()
    expect("RaidLedgerMasterLoot").toBeHidden()

    forge.openLoot({ { id = 20515 } })
    forge.click("RaidLedgerMasterLootRoll")
    expect(forge.errors()).toEqual({})
end)

test("FR-RL-014 the compact recipient chooser fits a full raid with long German names", function()
    local members = {
        "Tester", "Schattenherz", "Morgenroete", "Eisenfaust", "Lichtbringer",
        "Donnerhuf", "Nachtfalke", "Feuerherz", "Sturmwind", "Blutmond",
        "Grimmbart", "Silberpfeil", "Frostbeule", "Dunkelwald", "Kriegsschrei",
        "Heiligenlied", "Steinhaut", "Waldlaeuferin", "Zornesglut", "Mondsichel",
        "Knochenmann", "Seelenfaenger", "Glutfaust", "Runenwaechter", "Elfenstaub",
    }
    forge.closeLoot()
    forge.raid(members)
    forge.masterLoot(members)
    forge.openLoot({ { id = 20513 } })
    forge.click("RaidLedgerMasterLootLater")
    expect(forge.layoutIssues("RaidLedgerMasterLoot")).toEqual({})
end)

test("FR-RL-014 a corpse with many items fills the popup without empty space", function()
    local drops = {}
    forge.closeLoot()
    forge.slash("/ledger clear")
    for id = 30001, 30010 do table.insert(drops, { id = id }) end
    forge.openLoot(drops)
    expect(forge.rect("RaidLedgerMasterLoot").height).toBe(264)
    expect("RaidLedgerMasterLootItem10").toBeShown()
    expect(forge.layoutIssues("RaidLedgerMasterLoot")).toEqual({})
end)

test("FR-RL-014 the master-loot popup follows the ledger scale", function()
    forge.closeLoot()
    forge.slash("/ledger scale 80")
    forge.openLoot({ { id = 20513 } })
    expect(math.floor(forge.frame("RaidLedgerMasterLoot"):GetScale() * 100 + 0.5)).toBe(80)
    forge.closeLoot()
    forge.slash("/ledger scale 150")
    forge.openLoot({ { id = 20513 } })
    expect(math.floor(forge.frame("RaidLedgerMasterLoot"):GetScale() * 100 + 0.5)).toBe(150)
end)

test("FR-RL-014 the popup removes blank rows when the client loot list shrinks", function()
    local drops = {}
    for id = 30001, 30010 do table.insert(drops, { id = id }) end
    forge.closeLoot()
    forge.slash("/ledger clear")
    forge.slash("/ledger scale 100")
    forge.openLoot(drops)
    expect("RaidLedgerMasterLootItem10").toBeShown()
    forge.openLoot({ { id = 30001 }, { id = 30002 }, { id = 30003 } })
    expect("RaidLedgerMasterLootItem4").toBeHidden()
    expect(forge.rect("RaidLedgerMasterLoot").height).toBe(131)
end)

test("FR-RL-014 clicking another corpse row selects and assigns that item", function()
    forge.closeLoot()
    forge.raid({ "Tester", "Alice" })
    forge.masterLoot({ "Tester", "Alice" })
    forge.openLoot({ { id = 20513 }, { id = 21281 } })
    expect(forge.text("RaidLedgerMasterLootItem1")).toBe(TOME)
    forge.click("RaidLedgerMasterLootItem1")
    local _, green = forge.frame("RaidLedgerMasterLootItem1"):GetBackdropColor()
    expect(green).toBe(0.21)
    forge.click("RaidLedgerMasterLootLater")
    forge.click("RaidLedgerMasterLootMember1_2")
    forge.advance(0.1)
    expect(forge.awards()[table.getn(forge.awards())].slot).toBe(2)
end)
