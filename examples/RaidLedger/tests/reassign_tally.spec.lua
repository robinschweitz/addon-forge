-- Reassigning an award (/ledger set, CHANGE RECIPIENT, a shared correction)
-- moves its count in the item tally to the new recipient, so the "fewest items
-- this raid wins" rule ranks the next roll by who really has the item.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local TOME = "|cffa335ee|Hitem:21281:0:0:0:0:0:0:0:60|h[Grimoire of Shadow Bolt]|h|r"
local TOKEN = "|cffa335ee|Hitem:47242:0:0:0:0:0:0:0:80|h[Weiheabzeichen des Kreuzzugs]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.item(21281, { name = "Grimoire of Shadow Bolt", link = TOME, quality = 4 })
    forge.item(47242, { name = "Weiheabzeichen des Kreuzzugs", link = TOKEN, quality = 4 })
end)

local function db() return forge.saved("RaidLedgerDB") end

local function record(id)
    for _, r in ipairs(db().history) do
        if r.id == id then return r end
    end
end

-- tally runs /ledger tally and returns only the lines it printed.
local function tally()
    local before = #forge.chat()
    forge.slash("/ledger tally")
    local out = {}
    for i = before + 1, #forge.chat() do table.insert(out, forge.chat()[i]) end
    return table.concat(out, "\n")
end

local function lacks(text, needle)
    expect(string.find(text, needle, 1, true)).toBeNil()
end

local function award(id, rolls)
    forge.click("RaidLedgerTabButtonLoot")
    forge.slash("/ledger clear")
    forge.openLoot({ { id = id } })
    forge.slash("/ledger start")
    for _, r in ipairs(rolls) do forge.roll(r[1], r[2], r[3], r[4]) end
    forge.advance(31, 0.25)
    forge.clickText("RECORD AWARD")
    forge.closeLoot()
    return db().history[1]
end

test("an award counts for its winner", function()
    forge.raid({ "Alice", "Bob", "Cara", "Dora" })
    award(20513, { { "Alice", 70 } })
    local t = tally()
    expect(t).toContain("RaidLedger: Alice: 1 main spec, 0 off spec")
    lacks(t, "Bob:")
end)

test("/ledger set moves the count to the new recipient", function()
    forge.slash("/ledger set 1 Bob")
    expect(record(1).recipient).toBe("Bob")
    expect(record(1).spec).toBe("ms")
    local t = tally()
    expect(t).toContain("RaidLedger: Bob: 1 main spec, 0 off spec")
    lacks(t, "Alice:")
end)

test("the next roll ranks by the corrected tally", function()
    -- Bob now has the crest, so Alice wins the tome despite the lower roll.
    award(21281, { { "Alice", 20 }, { "Bob", 90 } })
    expect(record(2).recipient).toBe("Alice")
    local won = false
    for _, m in ipairs(forge.sent()) do
        if string.find(m.message, TOME .. " won by Alice (20)", 1, true) then won = true end
    end
    expect(won).toBe(true)
end)

test("an off-spec award keeps its spec and moves to the other player's off-spec count", function()
    award(20513, { { "Cara", 40, 1, 99 } })
    expect(record(3).spec).toBe("os")
    forge.slash("/ledger set 3 Dora")
    local t = tally()
    expect(t).toContain("RaidLedger: Dora: 0 main spec, 1 off spec")
    expect(t).toContain("RaidLedger: Alice: 1 main spec, 0 off spec")
    expect(t).toContain("RaidLedger: Bob: 1 main spec, 0 off spec")
    lacks(t, "Cara:")
end)

test("reassigning back and forth never counts an award twice", function()
    forge.slash("/ledger set 1 Cara")
    forge.slash("/ledger set 1 Bob")
    forge.slash("/ledger set 1 Cara")
    local t = tally()
    expect(t).toContain("RaidLedger: Cara: 1 main spec, 0 off spec")
    lacks(t, "Bob:")
end)

test("changing the recipient in the window updates the tally too", function()
    forge.click("RaidLedgerTabButtonAwards")
    forge.click(forge.findText("#2  ", true))
    expect(forge.findText("CHANGE RECIPIENT")).toBeTruthy()
    forge.type("RaidLedgerAwardRecipient", "Bob")
    forge.clickText("CHANGE RECIPIENT")
    expect(record(2).recipient).toBe("Bob")
    local t = tally()
    expect(t).toContain("RaidLedger: Bob: 1 main spec, 0 off spec")
    lacks(t, "Alice:")
end)

test("a reassigned token moves in the token tally only", function()
    award(47242, { { "Alice", 55 } })
    forge.slash("/ledger set 4 Dora")
    local t = tally()
    expect(t).toContain("RaidLedger: Dora: 1 main spec, 0 off spec (tokens)")
    expect(t).toContain("RaidLedger: Dora: 0 main spec, 1 off spec")   -- items unchanged
    lacks(t, "Alice: 1 main spec, 0 off spec (tokens)")
end)

test("an item the master looter keeps counts for its roll winner until it is reassigned", function()
    forge.masterLoot({ "Tester", "Alice", "Bob", "Cara", "Dora" })
    forge.slash("/ledger clear")
    forge.openLoot({ { id = 21281 } })
    forge.slash("/ledger start")
    forge.roll("Alice", 60)
    forge.advance(31, 0.25)
    GiveMasterLoot(1, 1)                       -- the master looter keeps it
    forge.advance(0.1)
    forge.closeLoot()
    expect(record(5).recipient).toBe("Alice")
    expect(record(5).holder).toBe("Tester")
    expect(tally()).toContain("RaidLedger: Alice: 1 main spec, 0 off spec")
    forge.slash("/ledger set 5 Alice")
    expect(record(5).state).toBe("manual")
    expect(tally()).toContain("RaidLedger: Alice: 1 main spec, 0 off spec")
    forge.slash("/ledger set 5 Bob")
    local t = tally()
    expect(t).toContain("RaidLedger: Bob: 2 main spec, 0 off spec")
    lacks(t, "Alice:")
end)

test("a correction from another ledger in the group moves the count", function()
    local r = record(5)
    forge.fire("CHAT_MSG_ADDON", "FLLedger", table.concat({ "A", db().session, r.origin, r.id, r.rev + 1, r.at,
        r.itemID, "", "Cara", "manual", 1, r.spec, r.roll or "", r.low or "", r.high or "", r.winner or "",
        r.rolls or 0, "", r.time or "" }, ";"), "RAID", "Cara")
    expect(record(5).recipient).toBe("Cara")
    local t = tally()
    expect(t).toContain("RaidLedger: Bob: 1 main spec, 0 off spec")
    expect(t).toContain("RaidLedger: Cara: 2 main spec, 0 off spec")
end)

test("the corrected tally survives /reload", function()
    forge.reload()
    local t = tally()
    expect(t).toContain("RaidLedger: Bob: 1 main spec, 0 off spec")
    expect(t).toContain("RaidLedger: Cara: 2 main spec, 0 off spec")
    expect(t).toContain("RaidLedger: Dora: 0 main spec, 1 off spec")
    expect(t).toContain("RaidLedger: Dora: 1 main spec, 0 off spec (tokens)")
end)
