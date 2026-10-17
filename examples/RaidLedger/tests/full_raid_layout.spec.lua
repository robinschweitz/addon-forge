-- A real raid has 25 members with names up to 12 letters, not the two-player
-- test party. Saves a drawing (.forge-runs/sketches) of the ledger during a
-- roll in a full German raid, to review how the window looks with real data.
local NAMES = {
    "Test", "Schattenklinge", "Morgenröte", "Eisenfaust", "Lichtbringer", "Donnerhuf", "Nachtschatten",
    "Feuerherz", "Sturmwind", "Blutmond", "Grimmbart", "Silberpfeil", "Frostbeule", "Dunkelwald",
    "Kriegsschrei", "Heiligenlicht", "Steinhaut", "Waldläuferin", "Zornesglut", "Mondsichel",
    "Knochenbrecher", "Seelenfänger", "Glutfaust", "Runenwächter", "Elfenstaub",
}

before_load(function()
    forge.locale("deDE", { RANDOM_ROLL_RESULT = "%1$s würfelt. Ergebnis: %2$d (%3$d-%4$d)" })
    forge.item(45509, { name = "Armschienen des Unsagbaren",
        link = "|cffa335ee|Hitem:45509:0:0:0:0:0:0:0:80|h[Armschienen des Unsagbaren]|h|r", quality = 4 })
end)

test("a full raid's roll fits the window", function()
    for i, name in ipairs(NAMES) do NAMES[i] = string.sub(name, 1, 12) end   -- WoW names: at most 12 letters
    forge.raid(NAMES)
    forge.masterLoot(NAMES)
    forge.openLoot({ { id = 45509 } })
    forge.slash("/ledger start")
    forge.roll(NAMES[2], 88)
    forge.roll("Morgenröte", 61, 21, 120)
    forge.roll("Eisenfaust", 99, 1, 99)
    forge.roll("Lichtbringer", 12)
    forge.advance(5, 0.25)
    if not RaidLedgerFrame:IsShown() then forge.slash("/ledger") end
    forge.sketch("full-raid-roll", "RaidLedgerFrame")
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
end)
