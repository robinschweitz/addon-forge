-- RaidLedger's SETTINGS panel lists who runs which addon: a hello query (HQ)
-- is answered with this wishlist's version (raid feedback 2026-10-19).
test("a ledger's hello query gets this wishlist's version", function()
    forge.raid({ "Tester", "Alice" })
    local before = #forge.addonMessages()
    forge.fire("CHAT_MSG_ADDON", "FLLedger", "HQ;Alice", "RAID", "Alice")
    forge.advance(6, 0.25)
    local found = false
    for i = before + 1, #forge.addonMessages() do
        if forge.addonMessages()[i].message == "HW;2.1.0" then found = true end
    end
    expect(found).toBe(true)
end)
