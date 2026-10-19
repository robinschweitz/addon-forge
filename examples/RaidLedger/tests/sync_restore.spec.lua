-- A master looter whose SavedVariables were lost (client crash) starts from an
-- empty ledger: awards restored from the group must keep their numbers, and new
-- awards must not reuse them.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
end)

test("restored awards keep their numbers and new awards continue after them", function()
    forge.raid({ "Alice", "Bob" })
    expect(forge.saved("RaidLedgerDB").nextID).toBe(0)
    forge.fire("CHAT_MSG_ADDON", "FLLedger",
        "A;Tester-77;Tester;7;2;1281052900;20513;;Bob;given;1;ms;61;1;100;Bob;1;;21:00", "RAID", "Alice")
    expect(forge.saved("RaidLedgerDB").history[1].id).toBe(7)
    expect(forge.saved("RaidLedgerDB").session).toBe("Tester-77")
    forge.openLoot({ { id = 20513 } })
    forge.type("RaidLedgerRecipient", "Alice")
    forge.clickText("RECORD AWARD")
    forge.closeLoot()
    expect(forge.saved("RaidLedgerDB").history[1].id).toBe(8)
end)
