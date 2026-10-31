-- FR-RL-004: LEEREN discards incomplete loot work, including open awards.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
end)

test("FR-RL-004 LEEREN removes open items and their saved awards", function()
    forge.raid({ "Tester", "Alice" })
    forge.masterLoot({ "Tester", "Alice" })
    forge.openLoot({ { id = 20513 } })
    forge.click("RaidLedgerMasterLootLater")
    forge.click("RaidLedgerMasterLootMember1_2")
    forge.advance(0.1)
    forge.closeLoot()
    expect(#forge.saved("RaidLedgerDB").history).toBe(1)
    expect(forge.findText("OPEN ITEMS (1)")).toBeTruthy()
    forge.slash("/ledger clear")
    expect(#forge.saved("RaidLedgerDB").history).toBe(0)
    expect(forge.findText("OPEN ITEMS (1)")).toBeNil()
    expect(forge.findText(CREST)).toBeNil()
end)
