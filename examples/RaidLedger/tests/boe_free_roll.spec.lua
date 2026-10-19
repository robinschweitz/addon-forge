-- Bind-on-equip items nobody rolls on (for this character's main or second
-- spec) are posted again: a free roll in which anyone may take the item for
-- any character. Rules chosen by the user on 2026-10-17: a popup asks the
-- master looter to start it now or later (/ledger free); only plain /rnd 100
-- counts, the highest roll wins (ties get a tie-break); the award counts in
-- nobody's tally and is exported with the website's BOE method ("boe").
local BRACERS = "|cffa335ee|Hitem:45509:0:0:0:0:0:0:0:80|h[Bracers of the Untold]|h|r"
local CLOAK = "|cffa335ee|Hitem:45510:0:0:0:0:0:0:0:80|h[Cloak of Whispers]|h|r"
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"

before_load(function()
    forge.item(45509, { name = "Bracers of the Untold", link = BRACERS, quality = 4, tooltip = { "ITEM_BIND_ON_EQUIP" } })
    forge.item(45510, { name = "Cloak of Whispers", link = CLOAK, quality = 4, tooltip = { "ITEM_BIND_ON_EQUIP" } })
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4, tooltip = { "ITEM_BIND_ON_PICKUP" } })
end)

local function db() return forge.saved("RaidLedgerDB") end

local function raidSaid(needle)
    local count = 0
    for _, m in ipairs(forge.sent()) do
        if m.chatType == "RAID" and string.find(m.message, needle, 1, true) then count = count + 1 end
    end
    return count
end

local function lastPopup()
    local popups = forge.popups()
    return popups[#popups]
end

local function startsShared()
    local count = 0
    for _, m in ipairs(forge.addonMessages()) do
        if string.sub(m.message, 1, 2) == "S;" then count = count + 1 end
    end
    return count
end

test("an item that does not bind on equip ends without takers as before", function()
    forge.raid({ "Alice", "Bob", "Cara", "Dora" })
    forge.openLoot({ { id = 20513 } })
    forge.slash("/ledger start")
    forge.advance(31, 0.25)
    expect(raidSaid("[Loot] " .. CREST .. " - nobody wanted it.")).toBe(1)
    expect(#forge.popups()).toBe(0)
    forge.closeLoot()
    forge.slash("/ledger clear")
end)

test("a BoE roll without takers asks whether to start a free roll now", function()
    forge.openLoot({ { id = 45509 } })
    forge.slash("/ledger start")
    forge.roll("Alice", 300, 1, 1000)          -- not a valid roll
    forge.advance(31, 0.25)
    expect(raidSaid("[Loot] " .. BRACERS .. " - nobody wanted it.")).toBe(1)
    expect(lastPopup().which).toBe("RAIDLEDGER_FREE_ROLL")
    expect(lastPopup().text1).toBe(BRACERS)
    expect(raidSaid("free BoE roll")).toBe(0)  -- nothing starts until the master looter decides
end)

test("starting it announces a free roll for any character", function()
    local shared = startsShared()
    StaticPopupDialogs["RAIDLEDGER_FREE_ROLL"].OnAccept(nil, lastPopup().data)
    expect(raidSaid("[Loot] " .. BRACERS .. " - free BoE roll for any character! /rnd 100, 30 seconds.")).toBe(1)
    expect(forge.findText("30-second free BoE roll started.")).toBeTruthy()
    expect(startsShared()).toBe(shared)        -- wishlists only prompt for spec rolls
end)

test("only /rnd 100 counts and the highest roll wins, whatever the tallies", function()
    forge.roll("Alice", 99, 1, 99)             -- off-spec range: not in a free roll
    forge.roll("Bob", 40)
    forge.roll("Cara", 110, 21, 120)           -- enhanced: not in a free roll
    forge.roll("Dora", 70)
    forge.roll("Bob", 95)                      -- re-roll: ignored
    forge.advance(31, 0.25)
    expect(raidSaid("[Loot] " .. BRACERS .. " - free BoE roll won by Dora (70).")).toBe(1)
    expect(forge.findText("WINNER: Dora (70)")).toBeTruthy()
    forge.clickText("RECORD AWARD")
    forge.closeLoot()
    local record = db().history[1]
    expect(record.recipient).toBe("Dora")
    expect(record.spec).toBe("boe")
    expect(record.roll).toBe(70)
    expect(raidSaid("[Loot] " .. BRACERS .. " goes to Dora - BoE.")).toBe(1)
    local notes = {}
    for _, r in ipairs(record.rollLog) do notes[r.name .. (r.note and (":" .. r.note) or "")] = true end
    expect(notes["Alice:1-99"]).toBe(true)
    expect(notes["Cara:21-120"]).toBe(true)
    expect(notes["Bob:re-roll"]).toBe(true)
end)

test("a BoE award counts for nobody", function()
    forge.slash("/ledger tally")
    expect(forge.chat()).toContain("RaidLedger: no items counted this raid yet.")
    forge.click("RaidLedgerTabButtonTally")
    forge.hover(forge.findText("Dora"))
    local found = false
    for _, line in ipairs(forge.tooltip()) do
        if string.find(line, "Dora this raid: items 0 MS / 0 OS", 1, true) then found = true end
    end
    expect(found).toBe(true)
end)

test("the export marks the award with the website's BoE method", function()
    forge.slash("/ledger raid 42")
    forge.slash("/ledger export")
    expect(forge.text("RaidLedgerExportText")).toContain(";45509;Dora;manual;70;boe;1-100;Dora")
    forge.clickText("BACK")
end)

test("later: decline the popup, then start it with /ledger free", function()
    forge.openLoot({ { id = 45510 } })
    forge.slash("/ledger start")
    forge.advance(31, 0.25)
    expect(lastPopup().which).toBe("RAIDLEDGER_FREE_ROLL")
    expect(lastPopup().text1).toBe(CLOAK)
    -- "Later": nothing happens; the item stays in the list.
    expect(raidSaid("[Loot] " .. CLOAK .. " - free BoE roll")).toBe(0)
    forge.slash("/ledger free")
    expect(raidSaid("[Loot] " .. CLOAK .. " - free BoE roll for any character! /rnd 100, 30 seconds.")).toBe(1)
    forge.slash("/ledger free")                -- already running
    expect(forge.chat()).toContain("RaidLedger: a roll is already running for this item.")
end)

test("a tie in a free roll gets a tie-break among the tied players", function()
    forge.roll("Alice", 50)
    forge.roll("Bob", 50)
    forge.advance(31, 0.25)
    expect(raidSaid("[Loot] " .. CLOAK .. " - tie between Alice and Bob (50)! Alice, Bob: /rnd again, 15 seconds.")).toBe(1)
    forge.roll("Alice", 80, 1, 99)             -- still only /rnd 100
    forge.roll("Bob", 20)
    forge.advance(16, 0.25)
    expect(raidSaid("[Loot] " .. CLOAK .. " - free BoE roll won by Bob (20).")).toBe(1)
    forge.closeLoot()
end)

test("/ledger free needs a selected loot item", function()
    forge.slash("/ledger clear")
    forge.slash("/ledger free")
    expect(forge.findText("Select a master-loot item before starting a roll.")).toBeTruthy()
end)
