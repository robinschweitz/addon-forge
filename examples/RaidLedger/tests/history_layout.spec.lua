-- The VERLAUF tab with real data on a German client (DESIGN.md): many saved
-- raids, each with 25 raiders with long names and many awards. Saves
-- drawings (.forge-runs/sketches) to compare with a live screenshot.
local NAMES = {
    "Schattenherz", "Morgenröte", "Eisenfaust", "Lichtbringer", "Donnerhuf", "Nachtfalke",
    "Feuerherz", "Sturmwind", "Blutmond", "Grimmbart", "Silberpfeil", "Frostbeule", "Dunkelwald",
    "Kriegsschrei", "Heiligenlied", "Steinhaut", "Waldläuferin", "Zornesglut", "Mondsichel",
    "Knochenmann", "Seelenfänger", "Glutfaust", "Runenwächter", "Elfenstaub", "Test",
}
local ITEM = "|cffa335ee|Hitem:45510:0:0:0:0:0:0:0:80|h[Schulterschutz des unerschütterlichen Wächters]|h|r"
local TOKEN = "|cffa335ee|Hitem:47242:0:0:0:0:0:0:0:80|h[Weiheabzeichen]|h|r"

local function savedRaid(n)
    local start = 1281052900 - n * 7 * 86400
    local history = {}
    for i = 1, 40 do
        local name = NAMES[(i - 1) % 25 + 1]
        local token = i % 5 == 0
        table.insert(history, 1, { id = n * 100 + i, rev = 1, at = start + i * 60, time = "20:" .. string.format("%02d", i % 60),
            item = token and TOKEN or ITEM, itemID = token and 47242 or 45510, recipient = name, state = "given",
            confirmed = true, spec = i % 3 == 0 and "os" or "ms", roll = 50 + i, low = 1, high = 100, winner = name,
            token = token or nil, rollLog = {}, origin = "Schattenherz" })
    end
    return { session = "Schattenherz-" .. start, recorder = "Schattenherz", startedAt = start, raidID = 100000 + n,
        history = history, tallyAdjust = {}, closedAt = start + 4 * 3600 }
end

before_load(function()
    forge.locale("deDE", { RANDOM_ROLL_RESULT = "%1$s würfelt. Ergebnis: %2$d (%3$d-%4$d)" })
    forge.item(45510, { name = "Schulterschutz des unerschütterlichen Wächters", link = ITEM, quality = 4 })
    forge.item(47242, { name = "Weiheabzeichen", link = TOKEN, quality = 4 })
    local raids = {}
    for n = 1, 30 do raids[n] = savedRaid(n) end
    forge.setSaved("RaidLedgerDB", { history = {}, raids = raids, keepRaids = 30, nextID = 4000 })
end)

test("VERLAUF fits 30 saved raids with 25 raiders each", function()
    local members = {}
    for i, name in ipairs(NAMES) do members[i] = { name = name, subgroup = math.ceil(i / 5) } end
    forge.raid(members)
    if not RaidLedgerFrame:IsShown() then forge.slash("/ledger") end
    forge.click("RaidLedgerTabButtonHistory")
    expect(forge.layoutIssues(RaidLedgerFrame)).toEqual({})
    forge.sketch("history-list", RaidLedgerFrame)
    forge.click("RaidLedgerRaidRow1")
    expect(RaidLedgerRaidList.heading:GetText()).toContain("30")
    expect(forge.text("RaidLedgerRaidTally1")).toContain("Blutmond")
    expect(forge.layoutIssues(RaidLedgerFrame)).toEqual({})
    forge.sketch("history-raid", RaidLedgerFrame)
    forge.click("RaidLedgerRaidShow")
    expect(forge.layoutIssues(RaidLedgerFrame)).toEqual({})
    forge.sketch("history-awards", RaidLedgerFrame)
    forge.click("RaidLedgerTabButtonLoot")
    expect(forge.layoutIssues(RaidLedgerFrame)).toEqual({})
    expect(forge.errors()).toEqual({})
end)
