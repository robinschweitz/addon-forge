-- Bugs reported live on 2026-10-17: the roll countdown in the window did not
-- tick down, and a re-parked award the master looter then gave to himself
-- (he won it) stayed OPEN.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
end)

local function db() return forge.saved("RaidLedgerDB") end

test("the roll countdown in the window ticks down without new rolls", function()
    forge.raid({ "Alice", "Bob" })
    forge.openLoot({ { id = 20513 } })
    forge.slash("/ledger start")
    expect(forge.findText("0 rolls  |  30s remaining")).toBeTruthy()
    forge.advance(10, 0.25)
    expect(forge.findText("0 rolls  |  20s remaining")).toBeTruthy()
    forge.roll("Tester", 40)
    forge.advance(9, 0.25)
    expect(forge.findText("1 rolls  |  11s remaining")).toBeTruthy()
    forge.advance(12, 0.25)
    expect(forge.findText("Tester won (40).")).toBeTruthy()
    forge.click("RaidLedgerAward")
    forge.closeLoot()
    expect(db().history[1].recipient).toBe("Tester")
end)

test("a re-parked award the master looter gives himself is no longer open", function()
    -- Re-park the award with the master looter...
    forge.click("RaidLedgerTabButtonAwards")
    forge.click(forge.findText("#1  ", true))
    forge.click("RaidLedgerAwardPark")          -- ZURÜCK IN BEUTE
    local record = db().history[1]
    expect(record.state).toBe("parked")
    expect(record.recipient).toBe("Tester")
    -- Open items wait in BEUTE only (raid of 2026-10-26).
    expect(forge.findText("#1  ", true)).toBeNil()
    forge.click("RaidLedgerTabButtonLoot")
    expect(forge.findText("OPEN ITEMS (1)")).toBeTruthy()
    -- ...then he won it: give it to himself by hand.
    forge.slash("/ledger set 1 Tester")
    record = db().history[1]
    expect(record.recipient).toBe("Tester")
    expect(record.state).toBe("manual")
    expect(forge.findText("OPEN ITEMS (1)")).toBeNil()
    forge.click("RaidLedgerTabButtonAwards")
    forge.click(forge.findText("#1  ", true))
    expect(forge.findText("BACK TO LOOT")).toBeTruthy()
end)

test("/ledger set to the master looter closes an open award too", function()
    forge.click("RaidLedgerAwardPark")         -- award #1 is still selected
    expect(db().history[1].state).toBe("parked")
    forge.slash("/ledger set 1 Tester")
    expect(db().history[1].state).toBe("manual")
    expect(forge.findText("OPEN")).toBeFalsy()
end)

test("an item kept for another winner is theirs; a correction to the master looter makes it his", function()
    forge.masterLoot({ "Tester", "Alice", "Bob" })
    forge.slash("/ledger clear")
    forge.openLoot({ { id = 20513 } })
    forge.slash("/ledger start")
    forge.roll("Bob", 70)
    forge.advance(31, 0.25)
    GiveMasterLoot(1, 1)                       -- kept to hand over to Bob
    forge.advance(0.1)
    forge.closeLoot()
    expect(db().history[1].recipient).toBe("Bob")
    local id = db().history[1].id
    forge.slash("/ledger set " .. id .. " Tester")
    expect(db().history[1].state).toBe("manual")
    expect(db().history[1].recipient).toBe("Tester")
end)
