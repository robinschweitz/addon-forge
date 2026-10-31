-- Every award keeps what was rolled for it, including ignored rolls and
-- tie-breaks; clicking an award shows that list. CLEAR empties old loot.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local TOME = "|cffa335ee|Hitem:21281:0:0:0:0:0:0:0:60|h[Grimoire of Shadow Bolt]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.item(21281, { name = "Grimoire of Shadow Bolt", link = TOME, quality = 4 })
    -- One award saved by version 1.0, which kept no rolls.
    forge.setSaved("RaidLedgerDB", { history = {
        { item = TOME, recipient = "Oldie", rolls = 4, time = "20:00" },
    } })
end)

local function db() return forge.saved("RaidLedgerDB") end

local function wheel(pane, delta)
    local frame = forge.frame(pane)
    frame:GetScript("OnMouseWheel")(frame, delta)
end

test("the roll log keeps counted, ignored and tie-break rolls in order", function()
    forge.raid({ "Alice", "Bob", "Cara" })
    forge.openLoot({ { id = 20513 } })
    forge.slash("/ledger start")
    forge.roll("Cara", 20)
    forge.roll("Alice", 97)
    forge.roll("Bob", 97)
    forge.roll("Alice", 99)                 -- re-roll
    forge.roll("Cara", 600, 1, 1000)        -- wrong range
    forge.advance(31, 0.25)                 -- tie: Alice and Bob
    forge.roll("Cara", 100)                 -- not in the tie-break
    forge.roll("Bob", 64)
    forge.roll("Alice", 12)
    forge.advance(16, 0.25)
    expect(forge.text(forge.findText("Bob"))).toBe("Bob")   -- the winner is prefilled
    forge.click("RaidLedgerAward")
    forge.closeLoot()
    local log = db().history[1].rollLog
    local seen = {}
    for i, r in ipairs(log) do
        seen[i] = r.name .. ":" .. r.value .. ":" .. r.round .. ":" .. (r.note or "")
    end
    expect(seen).toEqual({
        "Alice:97:1:", "Bob:97:1:", "Cara:20:1:", "Alice:99:1:re-roll", "Cara:600:1:1-1000",
        "Bob:64:2:", "Alice:12:2:", "Cara:100:2:not in tie-break",
    })
end)

test("clicking an award shows its rolls, marking the winner and ignored rolls", function()
    forge.click("RaidLedgerTabButtonAwards")
    forge.click(forge.findText("#2  ", true))
    expect(forge.findText("ROLLS (8)")).toBeTruthy()
    expect(forge.findText("Bob  (tie-break 1)  - won  (MS, 0 items)")).toBeTruthy()
    expect(forge.findText("|cff777777Alice  - ignored: re-roll|r")).toBeTruthy()
    expect(forge.findText("|cff777777Cara  (tie-break 1)  - ignored: not in tie-break|r")).toBeTruthy()
    expect(forge.findText("97")).toBeTruthy()
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
end)

test("clicking a roll-log line does not leave the log", function()
    forge.click(forge.findText("Bob  (tie-break 1)  - won  (MS, 0 items)"))
    expect(forge.findText("ROLLS (8)")).toBeTruthy()
    expect(forge.text("RaidLedgerAwardRecipient")).toBe("Bob")   -- the click picks the player
end)

test("an award from before roll logs says its rolls were not recorded", function()
    forge.click(forge.findText("#1  ", true))
    expect(forge.findText("ROLLS (0)")).toBeTruthy()
    expect(forge.findText("Rolls were not recorded\nfor this older award")).toBeTruthy()
end)

test("the loot tab shows the master loot items again", function()
    forge.click("RaidLedgerTabButtonLoot")
    expect(forge.findText("LOOT (0)")).toBeTruthy()
    expect(forge.findText("Open the master loot window\nPlayers can then use /rnd")).toBeTruthy()
end)

test("an award without a roll says so", function()
    forge.openLoot({ { id = 21281 } })
    forge.type("RaidLedgerRecipient", "Cara")
    forge.click("RaidLedgerAward")
    forge.closeLoot()
    forge.click("RaidLedgerTabButtonAwards")
    forge.click(forge.findText("#3  ", true))
    expect(forge.findText("Awarded without a /rnd roll")).toBeTruthy()
end)

test("long roll logs scroll with the mouse wheel", function()
    local names = {}
    for i = 1, 14 do names[i] = "Raider" .. string.char(64 + i) end
    forge.raid(names)
    forge.click("RaidLedgerTabButtonLoot")
    forge.openLoot({ { id = 20513 } })
    expect(forge.findText("LOOT (1)")).toBeTruthy()
    forge.slash("/ledger start")
    for i, name in ipairs(names) do forge.roll(name, 100 - i) end
    forge.advance(31, 0.25)
    forge.click("RaidLedgerAward")
    forge.closeLoot()
    forge.click("RaidLedgerTabButtonAwards")
    forge.click(forge.findText("#4  ", true))
    expect(forge.findText("ROLLS (14, SCROLL)")).toBeTruthy()
    expect(forge.findText("RaiderN  (MS, 0 items)")).toBeNil()
    wheel("RaidLedgerAwardDetail", -10)
    expect(forge.findText("RaiderN  (MS, 0 items)")).toBeTruthy()
    expect(forge.findText("RaiderA  - won  (MS, 0 items)")).toBeNil()
    wheel("RaidLedgerAwardDetail", 10)
    expect(forge.findText("RaiderA  - won  (MS, 0 items)")).toBeTruthy()
end)

test("roll logs survive /reload", function()
    forge.reload()
    expect(db().history[1].rollLog[1].name).toBe("RaiderA")
    expect(table.getn(db().history[1].rollLog)).toBe(14)
end)

test("NEW RAID asks first, then empties all old loot", function()
    forge.click("RaidLedgerTabButtonAwards")
    forge.clickText("NEW RAID")
    expect(forge.popups()[1].which).toBe("RAIDLEDGER_NEW_RAID")
    expect(table.getn(db().history)).toBe(4)
    StaticPopupDialogs["RAIDLEDGER_NEW_RAID"].OnAccept()
    expect(table.getn(db().history)).toBe(0)
    expect(forge.findText("No awards recorded in this ledger.")).toBeTruthy()
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
end)

test("/ledger newraid confirm clears without asking", function()
    forge.party({ "Alice" })
    forge.click("RaidLedgerTabButtonLoot")
    forge.openLoot({ { id = 21281 } })
    forge.type("RaidLedgerRecipient", "Alice")
    forge.click("RaidLedgerAward")
    forge.closeLoot()
    local popups = table.getn(forge.popups())
    forge.slash("/ledger newraid confirm")
    expect(table.getn(forge.popups())).toBe(popups)
    expect(table.getn(db().history)).toBe(0)
end)
