-- A busy raid evening (UI feedback 2026-10-19: "cluttered with a lot of
-- items"): 25 raiders, six drops on one corpse, parked items waiting, a roll
-- with many rollers and a long award list. Saves drawings to review.
local NAMES = {
    "Test", "Schattenherz", "Morgenröte", "Eisenfaust", "Lichtbringer", "Donnerhuf", "Nachtfalke",
    "Feuerherz", "Sturmwind", "Blutmond", "Grimmbart", "Silberpfeil", "Frostbeule", "Dunkelwald",
    "Kriegsschrei", "Heiligenlied", "Steinhaut", "Waldläuferin", "Zornesglut", "Mondsichel",
    "Knochenmann", "Seelenfänger", "Glutfaust", "Runenwächter", "Elfenstaub",
}
local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local ITEMS = {
    [50415] = "Bryntroll, der Knochenarbiter",
    [50416] = "Schulterschutz des unerschütterlichen Wächters",
    [50417] = "Siegelring der verlorenen Hoffnung",
    [50418] = "Gamaschen des Sturmrufers",
    [50419] = "Halskette der gefallenen Sterne",
    [52027] = "Weiheabzeichen des Eroberers",
    [50420] = "Umhang der Unsagbaren",
    [50421] = "Armschienen des Unsagbaren",
}
local function linkOf(id) return "|cffa335ee|Hitem:" .. id .. ":0:0:0:0:0:0:0:80|h[" .. ITEMS[id] .. "]|h|r" end

before_load(function()
    forge.locale("deDE", { RANDOM_ROLL_RESULT = "%1$s würfelt. Ergebnis: %2$d (%3$d-%4$d)" })
    forge.unit("player", { name = "Test" })
    for id, name in pairs(ITEMS) do forge.item(id, { name = name, link = linkOf(id), quality = 4 }) end
end)

test("a busy evening: many items, open awards, a long roll and award list", function()
    local members = {}
    for i, name in ipairs(NAMES) do
        members[i] = { name = name, subgroup = math.ceil(i / 5), classToken = CLASSES[(i - 1) % 10 + 1], rank = i == 1 and 2 or 0 }
    end
    forge.raid(members)
    forge.masterLoot(NAMES)
    forge.slash("/ledger newraid confirm")
    -- Earlier bosses: awards, three of them parked with raiders.
    for i, id in ipairs({ 50420, 50421, 50419 }) do
        forge.openLoot({ { id = id } })
        forge.slash("/ledger start")
        forge.roll(NAMES[i + 1], 50 + i)
        forge.advance(31, 0.25)
        forge.clickText("GEBEN + ERFASSEN")
        forge.advance(0.5, 0.25)
        forge.closeLoot()
    end
    for _, id in ipairs({ 50417, 50418 }) do
        forge.openLoot({ { id = id } })
        forge.type(forge.frame("RaidLedgerRecipient"), "Seelenfänger")
        forge.click(forge.frame("RaidLedgerPark"))
        forge.advance(0.5, 0.25)
        forge.closeLoot()
    end
    -- This boss: six drops, two of them tokens.
    forge.openLoot({ { id = 50415 }, { id = 50416 }, { id = 52027 }, { id = 52027 }, { id = 50418 }, { id = 50419 } })
    forge.slash("/ledger start")
    for i = 2, 10 do forge.roll(NAMES[i], 10 * i - 7, i % 3 == 0 and 1 or nil, i % 3 == 0 and 99 or nil) end
    forge.advance(10, 0.25)
    forge.sketch("busy-rolling", RaidLedgerFrame)
    forge.advance(25, 0.25)
    forge.sketch("busy-decided", RaidLedgerFrame)
    expect(forge.layoutIssues(RaidLedgerFrame)).toEqual({})
    -- The awards and the tally of the same evening.
    forge.click("RaidLedgerTabButtonAwards")
    forge.click("RaidLedgerAwardLine2")
    expect(forge.layoutIssues(RaidLedgerFrame)).toEqual({})
    forge.sketch("busy-awards", RaidLedgerFrame)
    forge.click("RaidLedgerTabButtonTally")
    forge.click("RaidLedgerTallyRow3")
    forge.click("RaidLedgerTallyPlusms")
    expect(forge.layoutIssues(RaidLedgerFrame)).toEqual({})
    forge.sketch("busy-tally", RaidLedgerFrame)
    forge.click("RaidLedgerSettingsButton")
    expect(forge.layoutIssues(RaidLedgerFrame)).toEqual({})
    forge.sketch("busy-settings", RaidLedgerFrame)
    forge.click("RaidLedgerRaidButton")
    expect(forge.layoutIssues(RaidLedgerFrame)).toEqual({})
    forge.sketch("busy-raid", RaidLedgerFrame)
    expect(forge.errors()).toEqual({})
end)
