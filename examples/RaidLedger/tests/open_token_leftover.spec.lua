-- FR-RL-031: the copy of an open token bundle that nobody rolled for stays in
-- BEUTE, says that it was already rolled and nobody wanted it, and can be
-- handed out without a new roll, also to a player who already won a copy.
local TOKEN = "|cffa335ee|Hitem:52025:0:0:0:0:0:0:0:80|h[Weiheabzeichen des Bezwingers]|h|r"

before_load(function()
    forge.locale("deDE", { RANDOM_ROLL_RESULT = "%1$s würfelt. Ergebnis: %2$d (%3$d-%4$d)" })
    forge.item(52025, { name = "Weiheabzeichen des Bezwingers", link = TOKEN, quality = 4 })
end)

local function db() return forge.saved("RaidLedgerDB") end

local function tokensOf(name)
    local n = 0
    for _, record in ipairs(db().history) do
        if record.itemID == 52025 and record.recipient == name and record.state ~= "deleted" then n = n + 1 end
    end
    return n
end

local function rowShowing(text)
    for i = 1, 10 do
        local row = forge.frame("RaidLedgerItemRow" .. i)
        if row and row:IsShown() and string.find(forge.text(row) or "", text, 1, true) then return row end
    end
end

-- The raid of 2026-11: the master looter takes three tokens from the corpse,
-- rolls them later as one 3x bundle, and only two players roll.
local function takeTokens(copies)
    local names = { "Tester", "Alice", "Bob", "Cara" }
    forge.raid(names)
    forge.masterLoot(names)
    forge.slash("/ledger newraid confirm")
    forge.slash("/ledger clear")
    for _ = 1, copies do
        forge.openLoot({ { id = 52025 } })
        forge.click("RaidLedgerMasterLootLater")
        forge.click("RaidLedgerMasterLootMember1_1")
        forge.advance(0.1)
        forge.closeLoot()
    end
    if not forge.frame("RaidLedgerFrame"):IsShown() then forge.slash("/ledger") end
end

local function rollThreeTwoRollers()
    local names = { "Tester", "Alice", "Bob", "Cara" }
    forge.raid(names)
    forge.masterLoot(names)
    forge.slash("/ledger newraid confirm")
    forge.slash("/ledger clear")
    for _ = 1, 3 do
        forge.openLoot({ { id = 52025 } })
        forge.click("RaidLedgerMasterLootLater")
        forge.click("RaidLedgerMasterLootMember1_1")
        forge.advance(0.1)
        forge.closeLoot()
    end
    if not forge.frame("RaidLedgerFrame"):IsShown() then forge.slash("/ledger") end
    forge.click(rowShowing("3x " .. TOKEN))
    forge.click("RaidLedgerStart")
    forge.roll("Alice", 90)
    forge.roll("Bob", 80)
    forge.advance(31, 0.25)
    expect(tokensOf("Alice")).toBe(1)
    expect(tokensOf("Bob")).toBe(1)
end

test("FR-RL-031 the leftover copy stays in BEUTE and says nobody wanted it", function()
    rollThreeTwoRollers()
    local row = rowShowing(TOKEN)
    expect(row).toBeTruthy()
    expect(forge.text(row)).toBe(TOKEN)          -- one copy left, no "3x"
    forge.click(row)
    expect(forge.findText("NIEMAND")).toBeTruthy()
    expect(forge.text("RaidLedgerStart")).toBe("NOCHMAL WÜRFELN")
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
    forge.sketch("leftover-token", "RaidLedgerFrame")
end)

test("FR-RL-031 the leftover copy goes to a player who already won one, without a roll", function()
    rollThreeTwoRollers()
    forge.click(rowShowing(TOKEN))
    forge.type("RaidLedgerRecipient", "Alice")
    forge.click("RaidLedgerAward")
    forge.advance(0.5, 0.25)
    expect(tokensOf("Alice")).toBe(2)
    expect(tokensOf("Tester")).toBe(0)
    expect(rowShowing(TOKEN)).toBeNil()
    expect(forge.errors()).toEqual({})
end)

test("FR-RL-031 a copy of an open bundle is handed out without a roll", function()
    takeTokens(2)
    forge.click(rowShowing("2x " .. TOKEN))
    expect(forge.findText("Offenes Item, noch nicht gewürfelt.")).toBeTruthy()
    forge.type("RaidLedgerRecipient", "Cara")
    expect(forge.frame("RaidLedgerAward"):IsEnabled()).toBeTruthy()
    forge.click("RaidLedgerAward")
    forge.advance(0.5, 0.25)
    expect(tokensOf("Cara")).toBe(1)
    expect(tokensOf("Tester")).toBe(1)
    local row = rowShowing(TOKEN)
    expect(row).toBeTruthy()
    expect(forge.text(row)).toBe(TOKEN)
    expect(forge.errors()).toEqual({})
end)
