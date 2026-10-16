-- Layout with realistic, long content: nothing may overlap or poke out of its panel.
local LONG = "|cffa335ee|Hitem:40395:0:0:0:0:0:0:0:80|h[Torch of Holy Fire of the Infinite Dragonflight Champions]|h|r"
local CREST = "|cff1eff00|Hitem:20513:0:0:0:0:0:0:0:1|h[Abyssisches Wappen]|h|r"
local BOOTS = "|cff1eff00|Hitem:20514:0:0:0:0:0:0:0:1|h[Abyssische Panzersabatons des Kampfes]|h|r"

before_load(function()
    forge.item(40395, { name = "Torch of Holy Fire of the Infinite Dragonflight Champions", link = LONG, quality = 4 })
    forge.item(20513, { name = "Abyssisches Wappen", link = CREST, quality = 2 })
    forge.item(20514, { name = "Abyssische Panzersabatons des Kampfes", link = BOOTS, quality = 2 })
    local history = {}
    for i = 1, 4 do
        history[i] = { item = LONG, recipient = "Floleadygzmq", rolls = 12, time = "23:24" }
    end
    forge.setSaved("RaidLedgerDB", { history = history })
end)

test("full window with long names has no overlapping or overflowing elements", function()
    forge.party({ "Floleadygzmq", "Bernadettine", "Kristoffersen" })
    forge.openLoot({ { id = 40395 }, { id = 20513 }, { id = 20514 } })
    forge.slash("/ledger start")
    forge.roll("Floleadygzmq", 88)
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
end)

test("empty window has no layout issues", function()
    forge.closeLoot()
    forge.slash("/ledger clear")
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
end)

test("the ledger fits on a 1280x720 screen", function()
    local r = forge.rect("RaidLedgerFrame")
    expect(r.left >= 0 and r.right <= 1280 and r.bottom >= 0 and r.top <= 720).toBe(true)
end)
