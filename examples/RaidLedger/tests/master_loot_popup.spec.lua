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
    expect("RaidLedgerMasterLootDisenchant").toBeShown()
    expect("RaidLedgerMasterLootBank").toBeShown()

    forge.click("RaidLedgerMasterLootLater")
    expect("RaidLedgerMasterLootMembers").toBeShown()
    forge.click("RaidLedgerMasterLootMember1_2")
    forge.advance(0.1)
    expect(latestAward().state).toBe("parked")
    expect(latestAward().recipient).toBe("Alice")
    expect("RaidLedgerMasterLoot").toBeHidden()

    forge.closeLoot()
    expect("RaidLedgerMasterLoot").toBeHidden()

    forge.openLoot({ { id = 21281 } })
    forge.click("RaidLedgerMasterLootDisenchant")
    forge.advance(0.1)
    expect(latestAward().state).toBe("disenchanted")
    forge.closeLoot()

    forge.openLoot({ { id = 20514 } })
    forge.click("RaidLedgerMasterLootBank")
    forge.advance(0.1)
    expect(latestAward().state).toBe("bank")
    forge.closeLoot()

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
