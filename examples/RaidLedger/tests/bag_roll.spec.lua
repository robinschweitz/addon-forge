-- Raider feedback 2026-10-18: "auch auf Items im Inventar rollen lassen".
-- Alt+click an item in the bags (or /ledger roll <link>) starts a roll on it;
-- it is held by the roller, so the winner gets it by trade.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local TOME = "|cffa335ee|Hitem:40000:0:0:0:0:0:0:0:80|h[Tome of Testing]|h|r"
local bags = {}

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.item(40000, { name = "Tome of Testing", link = TOME, quality = 4 })
    -- The default bag frames are not emulated offline; the client's
    -- ContainerFrameItemButton_OnModifiedClick and GetContainerItemLink are
    -- stood in for here (bag 0 slot 1 holds the crest, slot 2 the tome).
    bags = { [0] = { CREST, TOME } }
    forge.stub("ContainerFrameItemButton_OnModifiedClick", function() end)
    forge.stub("GetContainerItemLink", function(bag, slot) return bags[bag] and bags[bag][slot] end)
    forge.stub("GetContainerNumSlots", function(bag) return bags[bag] and 16 or 0 end)
end)

local function db() return forge.saved("RaidLedgerDB") end

local function bagButton(bag, slot)
    local parent = { GetID = function() return bag end }
    return { GetID = function() return slot end, GetParent = function() return parent end }
end

local function clickBag(bag, slot, keys)
    forge.keys(keys)
    ContainerFrameItemButton_OnModifiedClick(bagButton(bag, slot), "LeftButton")
    forge.keys({})
end

local function raidSaid(text)
    for _, message in ipairs(forge.sent()) do
        if message.chatType == "RAID" and message.message == text then return true end
    end
    return false
end

test("only Alt+click starts a roll; Shift or Ctrl clicks are left to the game", function()
    forge.raid({ "Tester", "Alice", "Bob" })   -- the master looter is raid1
    forge.masterLoot({ "Tester", "Alice", "Bob" })
    clickBag(0, 1, { shift = true })
    clickBag(0, 1, { ctrl = true })
    clickBag(0, 1, { alt = true, shift = true })
    expect(table.getn(db() and db().history or {})).toBe(0)
end)

test("Alt+click on a bag item records it as held and starts the raid roll", function()
    RaidLedgerFrame:Hide()
    clickBag(0, 1, { alt = true })
    expect("RaidLedgerFrame").toBeShown()
    local record = db().history[1]
    expect(record.item).toBe(CREST)
    expect(record.state).toBe("held")
    expect(record.recipient).toBe("Tester")
    expect(raidSaid("[Loot] " .. CREST .. " - /rnd now! 30 seconds. /rnd 100 main spec (enhanced: 1+X to 100+X, X up to 50), /rnd 99 off spec.")).toBe(true)
    -- A second Alt+click does not restart the running roll.
    forge.roll("Alice", 70)
    clickBag(0, 1, { alt = true })
    expect(table.getn(db().history)).toBe(1)
    expect(forge.findText("1 rolls", true)).toBeTruthy()
end)

test("the winner is the recipient of the same award at once (no trade tracking)", function()
    forge.roll("Bob", 40)
    forge.advance(31, 0.25)
    expect(forge.findText("WINNER: Alice (70)")).toBeTruthy()
    forge.clickText("RECORD AWARD")
    local record = db().history[1]
    expect(table.getn(db().history)).toBe(1)
    expect(record.winner).toBe("Alice")
    expect(record.recipient).toBe("Alice")
    expect(record.state).toBe("manual")
    expect(record.spec).toBe("ms")
    expect(raidSaid("[Loot] " .. CREST .. " goes to Alice - main spec (Tester hands it over).")).toBe(true)
end)

test("an open award already held for that item is rolled, not recorded twice", function()
    forge.slash("/ledger roll " .. TOME)            -- first: recorded, roll starts
    expect(db().history[1].item).toBe(TOME)
    forge.advance(31, 0.25)                         -- nobody rolled: the award stays open
    local count = table.getn(db().history)
    clickBag(0, 2, { alt = true })
    expect(table.getn(db().history)).toBe(count)
    expect(raidSaid("[Loot] " .. TOME .. " - /rnd now! 30 seconds. /rnd 100 main spec (enhanced: 1+X to 100+X, X up to 50), /rnd 99 off spec.")).toBe(true)
end)

test("a raider who is not master looter or lead cannot start bag rolls", function()
    forge.slash("/ledger clear")
    forge.masterLoot({ "Alice", "Tester" })
    forge.stub("GetLootMethod", function() return "master", nil, 2 end)   -- Alice is master looter
    forge.leader(false)
    local count = table.getn(db().history)
    clickBag(0, 1, { alt = true })
    expect(table.getn(db().history)).toBe(count)
    expect(forge.chat()).toContain("RaidLedger: only the master looter or the raid lead can start rolls.")
end)

test("/ledger roll <itemID> finds the item in the bags (live plans cannot type links)", function()
    forge.slash("/ledger roll 40001")
    expect(forge.chat()).toContain("RaidLedger: item 40001 is not in your bags.")
    forge.leader(true)
    local count = table.getn(db().history)
    forge.slash("/ledger roll 40000")
    expect(table.getn(db().history)).toBe(count)                 -- the tome's open award is rolled again
    expect(forge.findText(TOME, true)).toBeTruthy()
end)

test("/ledger roll without an item link explains the usage", function()
    forge.slash("/ledger roll")
    expect(forge.chat()).toContain("RaidLedger: usage: /ledger roll <item link> (or Alt+click the item in your bags)")
end)

-- Raid feedback 2026-10-19: the next roll must show the winner's items so far
-- (announcement, the award's roll log and the window), not 0 again.
test("the next roll after an award counts the winner's item", function()
    forge.raid({ "Tester", "Alice", "Bob" })
    forge.masterLoot({ "Tester", "Alice", "Bob" })
    forge.slash("/ledger newraid confirm")
    forge.slash("/ledger clear")
    forge.openLoot({ { id = 20513 } })
    forge.slash("/ledger start")
    forge.roll("Tester", 60)
    forge.advance(31, 0.25)
    expect(raidSaid("[Loot] " .. CREST .. " won by Tester (60) - main spec, 0 MS / 0 OS items so far.")).toBe(true)
    forge.clickText("GIVE + RECORD")
    forge.advance(0.5, 0.25)
    forge.closeLoot()
    forge.slash("/ledger roll 20513")
    forge.roll("Tester", 45)
    forge.advance(31, 0.25)
    expect(raidSaid("[Loot] " .. CREST .. " won by Tester (45) - main spec, 1 MS / 0 OS items so far.")).toBe(true)
    forge.clickText("RECORD AWARD")
    expect(db().history[1].rollLog[1].tally).toBe(1)
    expect(db().history[2].rollLog[1].tally).toBe(0)
    -- The award's roll log in the window names the tally the ranking used.
    local r = db().history[1]
    forge.click("RaidLedgerTabButtonAwards")
    forge.clickText(string.format("#%d  %s  %s", r.id, r.time, CREST))
    expect(forge.text("RaidLedgerRoll1")).toBe("Tester  - won  (MS, 1 item)")
end)
