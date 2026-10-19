-- Token bundles (raid feedback 2026-10-19): identical tokens from one corpse
-- are one row ("3x"), rolled once; the best three win one each. A tie only
-- matters where it decides who gets the last copy. Each award hands out one
-- copy and the next winner follows.
local TOKEN = "|cffa335ee|Hitem:52025:0:0:0:0:0:0:0:80|h[Weiheabzeichen des Bezwingers]|h|r"
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"

before_load(function()
    forge.item(52025, { name = "Weiheabzeichen des Bezwingers", link = TOKEN, quality = 4 })
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
end)

local function db() return forge.saved("RaidLedgerDB") end

local function raidSaid(text)
    for _, m in ipairs(forge.sent()) do
        if m.message == text then return true end
    end
    return false
end

local function pick(text)
    for i = 1, 10 do
        local row = forge.frame("RaidLedgerItemRow" .. i)
        if row and row:IsShown() and forge.text(row) == text then return forge.click(row) end
    end
    error("no loot row shows " .. text)
end

local function tokenRoll(copies, rolls)
    forge.slash("/ledger newraid confirm")
    forge.slash("/ledger clear")
    local loot = {}
    for _ = 1, copies do table.insert(loot, { id = 52025 }) end
    table.insert(loot, { id = 20513 })
    forge.openLoot(loot)
    pick(copies .. "x " .. TOKEN)
    forge.slash("/ledger start")
    for _, r in ipairs(rolls) do forge.roll(r[1], r[2], r[3], r[4]) end
    forge.advance(31, 0.25)
end

test("identical tokens from one corpse are one row with their count", function()
    forge.raid({ "Tester", "Alice", "Bob", "Cara", "Dora" })
    forge.openLoot({ { id = 52025 }, { id = 52025 }, { id = 20513 }, { id = 52025 } })
    expect(forge.findText("3x " .. TOKEN)).toBeTruthy()
    expect(forge.findText(CREST)).toBeTruthy()
    forge.closeLoot()
end)

test("one roll: the best three win a token each, announced together", function()
    forge.masterLoot({ "Tester", "Alice", "Bob", "Cara", "Dora" })
    tokenRoll(3, { { "Alice", 90 }, { "Bob", 80 }, { "Cara", 70 }, { "Dora", 60 } })
    expect(raidSaid("[Loot] 3x " .. TOKEN .. " won by Alice (90), Bob (80), Cara (70).")).toBe(true)
    expect(forge.text(forge.frame("RaidLedgerRecipient"))).toBe("Alice")
    expect(forge.findText("WINNERS: Alice, Bob, Cara", true)).toBeTruthy()
    -- Every winner's roll is marked in the roll list, not only the first.
    expect(forge.findText("Bob  MS  - won")).toBeTruthy()
    expect(forge.findText("Cara  MS  - won")).toBeTruthy()
    expect(forge.findText("Dora  MS")).toBeTruthy()
end)

test("each handout gives one copy; the next winner is picked for the next", function()
    forge.clickText("GIVE + RECORD")
    forge.advance(0.5, 0.25)
    expect(db().history[1].recipient).toBe("Alice")
    expect(db().history[1].spec).toBe("ms")
    expect(db().history[1].token).toBe(true)
    expect(forge.findText("2x " .. TOKEN)).toBeTruthy()
    expect(forge.text(forge.frame("RaidLedgerRecipient"))).toBe("Bob")
    forge.clickText("GIVE + RECORD")
    forge.advance(0.5, 0.25)
    expect(db().history[1].recipient).toBe("Bob")
    expect(forge.text(forge.frame("RaidLedgerRecipient"))).toBe("Cara")
    forge.clickText("GIVE + RECORD")
    forge.advance(0.5, 0.25)
    expect(db().history[1].recipient).toBe("Cara")
    expect(db().history[1].roll).toBe(70)
    for i = 1, 10 do                                     -- all three handed out
        local row = forge.frame("RaidLedgerItemRow" .. i)
        if row and row:IsShown() then expect(string.find(forge.text(row) or "", TOKEN, 1, true)).toBeNil() end
    end
    expect(db().history[1].rollLog[1].name).toBe("Alice")   -- the log of the decision
    expect(db().history[1].rollLog[3].name).toBe("Cara")
    local given = {}
    for _, award in ipairs(forge.awards()) do table.insert(given, award.slot) end
    expect(given).toEqual({ 1, 2, 3 })
    forge.closeLoot()
end)

test("the token tally counts each winner once", function()
    forge.slash("/ledger tally")
    local text = table.concat(forge.chat(), "\n")
    expect(text).toContain("Alice: 1 main spec, 0 off spec (tokens)")
    expect(text).toContain("Cara: 1 main spec, 0 off spec (tokens)")
end)

test("a tie for the last copy is broken; ties above it do not matter", function()
    tokenRoll(2, { { "Alice", 90 }, { "Bob", 80 }, { "Cara", 80 } })
    expect(raidSaid("[Loot] " .. TOKEN .. " - tie between Bob and Cara (80)! Bob, Cara: /rnd again, 15 seconds.")).toBe(true)
    forge.roll("Cara", 40)
    forge.roll("Bob", 55)
    forge.advance(16, 0.25)
    expect(raidSaid("[Loot] 2x " .. TOKEN .. " won by Alice (90), Bob (55).")).toBe(true)
    forge.closeLoot()
    tokenRoll(3, { { "Alice", 90 }, { "Bob", 90 }, { "Cara", 70 }, { "Dora", 60 } })
    expect(raidSaid("[Loot] 3x " .. TOKEN .. " won by Alice (90), Bob (90), Cara (70).")).toBe(true)
    forge.closeLoot()
end)

test("fewer takers than tokens: the rest is announced as unwanted", function()
    tokenRoll(3, { { "Alice", 90 }, { "Bob", 50, 1, 99 } })
    expect(raidSaid("[Loot] 3x " .. TOKEN .. " won by Alice (90), Bob (50).")).toBe(true)
    expect(raidSaid("[Loot] " .. TOKEN .. " - 1 left: nobody wanted it.")).toBe(true)
    forge.closeLoot()
end)

test("a winner's pass gives the copy to the next-best roll", function()
    tokenRoll(2, { { "Alice", 90 }, { "Bob", 80 }, { "Cara", 70 } })
    forge.slash("/ledger pass Bob")
    expect(raidSaid("[Loot] 2x " .. TOKEN .. " won by Alice (90), Cara (70).")).toBe(true)
    forge.closeLoot()
end)
