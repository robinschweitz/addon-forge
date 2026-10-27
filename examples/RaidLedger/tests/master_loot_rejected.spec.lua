-- FR-RL-015: a rejected master-loot request has no loot receipt.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.stub("GiveMasterLoot", function() end)
end)

test("FR-RL-015 a rejected hand-out records nothing and leaves one loot row", function()
    forge.masterLoot({ "Tester", "Alice" })
    forge.openLoot({ { id = 20513 } })
    forge.type("RaidLedgerRecipient", "Alice")
    forge.click("RaidLedgerAward")
    forge.advance(0.1)
    expect(#forge.saved("RaidLedgerDB").history).toBe(0)
    expect(forge.findText(CREST)).toBeTruthy()
end)
