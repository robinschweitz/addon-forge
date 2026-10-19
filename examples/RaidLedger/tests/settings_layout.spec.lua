-- The SETTINGS panel in a German client with a full 25-player raid: long
-- names, several editors, a mix of RaidLedger, RaidWishlist and no addon.
-- Saves drawings (.forge-runs/sketches) of the panel and of a token bundle.
local NAMES = {
    "Test", "Schattenherz", "Morgenröte", "Eisenfaust", "Lichtbringer", "Donnerhuf", "Nachtfalke",
    "Feuerherz", "Sturmwind", "Blutmond", "Grimmbart", "Silberpfeil", "Frostbeule", "Dunkelwald",
    "Kriegsschrei", "Heiligenlied", "Steinhaut", "Waldläuferin", "Zornesglut", "Mondsichel",
    "Knochenmann", "Seelenfänger", "Glutfaust", "Runenwächter", "Elfenstaub",
}
local TOKEN = "|cffa335ee|Hitem:52027:0:0:0:0:0:0:0:80|h[Weiheabzeichen des Eroberers]|h|r"

before_load(function()
    forge.locale("deDE", { RANDOM_ROLL_RESULT = "%1$s würfelt. Ergebnis: %2$d (%3$d-%4$d)" })
    forge.unit("player", { name = "Test" })
    forge.item(52027, { name = "Weiheabzeichen des Eroberers", link = TOKEN, quality = 4 })
end)

local function receive(message, sender)
    forge.fire("CHAT_MSG_ADDON", "FLLedger", message, "RAID", sender)
end

test("the German settings panel fits a full raid", function()
    local members = {}
    for i, name in ipairs(NAMES) do members[i] = { name = name, subgroup = math.ceil(i / 5), rank = i == 1 and 2 or 0 } end
    forge.raid(members)
    for i, name in ipairs(NAMES) do
        if i > 1 and i % 3 == 0 then receive("H;2.4.0;0", name)
        elseif i > 1 and i % 3 == 1 then receive("HW;1.5.0", name) end
    end
    for _, name in ipairs({ "Schattenherz", "Lichtbringer", "Seelenfänger", "Runenwächter", "Waldläuferin" }) do
        forge.slash("/ledger allow " .. name)
    end
    forge.slash("/ledger settings")
    expect(forge.findText("EINSTELLUNGEN")).toBeTruthy()
    expect(forge.findText("Seelenfänger")).toBeTruthy()
    expect(forge.findText("ADDON IN DER GRUPPE (17/25)")).toBeTruthy()
    expect(forge.findText("Waldläuferin  2.4.0")).toBeTruthy()
    expect(forge.layoutIssues(RaidLedgerFrame)).toEqual({})
    forge.sketch("settings-full-raid", RaidLedgerFrame)
end)

test("a German token bundle with its winners fits the loot view", function()
    forge.click("RaidLedgerTabButtonLoot")
    forge.masterLoot(NAMES)
    forge.openLoot({ { id = 52027 }, { id = 52027 }, { id = 52027 } })
    expect(forge.findText("3x " .. TOKEN)).toBeTruthy()
    forge.slash("/ledger start")
    forge.roll("Schattenherz", 88)
    forge.roll("Seelenfänger", 71)
    forge.roll("Runenwächter", 64)
    forge.roll("Waldläuferin", 12, 1, 99)
    forge.advance(31, 0.25)
    expect(forge.findText("GEWINNER: Schattenherz, Seelenfänger, Runenwächter")).toBeTruthy()
    expect(forge.layoutIssues(RaidLedgerFrame)).toEqual({})
    forge.sketch("token-bundle", RaidLedgerFrame)
end)
