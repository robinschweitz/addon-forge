-- FR-RL-034 (raid feedback 2026-11-17): "wenn jemand mal zu spät gerollt hat
-- und wir das erlauben, muss man auch bei Enhance die Punkte mitangeben
-- können". A /rnd after the roll ended stays in that roll's log as "too
-- late" and does not count; right-click ALLOW counts it, and the usual menu
-- then sets its spec or points. The winner is decided again.
local BRACERS = "|cffa335ee|Hitem:45509:0:0:0:0:0:0:0:80|h[Bracers of the Untold]|h|r"
local BELT = "|cffa335ee|Hitem:45511:0:0:0:0:0:0:0:80|h[Belt of the Late]|h|r"

before_load(function()
    forge.item(45509, { name = "Bracers of the Untold", link = BRACERS, quality = 4 })
    forge.item(45511, { name = "Belt of the Late", link = BELT, quality = 4 })
end)

local mark = 0
local function raidSaid(needle)
    local count = 0
    local sent = forge.sent()
    for i = mark + 1, #sent do
        local m = sent[i]
        if m.chatType == "RAID" and string.find(m.message, needle, 1, true) then count = count + 1 end
    end
    return count
end

local function rollRow(name)
    for _, prefix in ipairs({ "RaidLedgerRollLine", "RaidLedgerRoll" }) do
        for i = 1, 10 do
            local row = forge.frame(prefix .. i)
            if row and row:IsVisible() and row.playerName == name then return row end
        end
    end
end

local function logOf(log, name)
    for _, r in ipairs(log or {}) do if r.name == name then return r end end
end

local function fresh(id)
    mark = #forge.sent()
    forge.raid({ "Tester", "Alice", "Bob", "Cara" })
    forge.masterLoot({ "Tester", "Alice", "Bob", "Cara" })
    forge.click("RaidLedgerTabButtonLoot")
    forge.closeLoot()
    forge.slash("/ledger clear")
    forge.openLoot({ { id = id or 45509 } })
    forge.slash("/ledger start")
end

test("FR-RL-034 a roll after the end is logged as too late and does not count", function()
    fresh()
    forge.roll("Alice", 80)
    forge.advance(31, 0.25)
    expect(raidSaid("won by Alice (80)")).toBe(1)
    forge.roll("Bob", 90)
    expect(raidSaid("won by Bob")).toBe(0)
    expect(forge.text(rollRow("Bob"))).toContain("Bob  - ignored: too late")
    expect(forge.findText("Bob rolled too late (90): right-click the roll to allow it.", true)).toBeTruthy()
    -- A late re-roll of a player who already rolled stays a re-roll.
    forge.roll("Alice", 99)
    expect(forge.findText("Alice  - ignored: re-roll", true)).toBeTruthy()
end)

test("FR-RL-034 right-click ALLOW counts the late roll and the winner is decided again", function()
    forge.click(rollRow("Bob"), "RightButton")
    expect("RaidLedgerRollMenuAllow").toBeShown()
    expect(forge.layoutIssues("RaidLedgerRollMenu")).toEqual({})
    forge.sketch("late-roll-menu", "RaidLedgerFrame")
    expect(forge.frame("RaidLedgerRollMenuPass"):IsShown()).toBeFalsy()
    forge.click("RaidLedgerRollMenuAllow")
    expect(raidSaid("Bob's late roll counts")).toBe(1)
    expect(raidSaid("won by Bob (90)")).toBe(1)
    -- Once allowed, it is an ordinary roll: the menu offers the recounts.
    forge.click(rollRow("Bob"), "RightButton")
    expect("RaidLedgerRollMenuEnhanced").toBeShown()
    expect(forge.frame("RaidLedgerRollMenuAllow"):IsShown()).toBeFalsy()
    forge.click(rollRow("Bob"), "RightButton")
end)

test("FR-RL-034 an allowed late enhanced roll takes its points", function()
    fresh()
    forge.roll("Alice", 100)
    forge.advance(31, 0.25)
    forge.roll("Bob", 110, 21, 120)                -- late, claims 20 EP
    forge.slash("/ledger count Bob allow")
    expect(raidSaid("won by Bob (110) - main spec 21-120")).toBe(1)
    forge.slash("/ledger count Bob enh 5")         -- had 5 EP: 95 from 6-105
    expect(raidSaid("won by Alice (100)")).toBe(2)
end)

test("FR-RL-034 a new roll ends the time for late rolls on the old one", function()
    fresh()
    forge.roll("Alice", 50)
    forge.advance(31, 0.25)
    forge.click("RaidLedgerAward")
    forge.advance(0.1)
    forge.closeLoot()
    forge.openLoot({ { id = 45511 } })
    forge.slash("/ledger start")
    forge.advance(31, 0.25)                        -- nobody rolls on the belt
    forge.roll("Cara", 70)                         -- late for the belt only
    local bracers = forge.saved("RaidLedgerDB").history[1]
    expect(logOf(bracers.rollLog, "Cara")).toBeFalsy()
    forge.slash("/ledger count Cara allow")
    expect(raidSaid("[Loot] " .. BELT .. " won by Cara (70)")).toBe(1)
end)

test("FR-RL-034 a late roll on an award already handed out is allowed in VERGABEN", function()
    fresh()
    forge.roll("Alice", 60)
    forge.advance(31, 0.25)
    forge.click("RaidLedgerAward")
    forge.advance(0.1)
    local record = forge.saved("RaidLedgerDB").history[1]
    expect(record.recipient).toBe("Alice")
    forge.roll("Bob", 75)
    expect(logOf(record.rollLog, "Bob").note).toBe("too late")
    forge.click("RaidLedgerTabButtonAwards")
    forge.click("RaidLedgerAwardLine1")
    forge.click(rollRow("Bob"), "RightButton")
    forge.click("RaidLedgerRollMenuAllow")
    expect(record.recipient).toBe("Bob")
    expect(raidSaid("[Loot] " .. BRACERS .. " goes to Bob - main spec (corrected).")).toBe(1)
    expect(forge.errors()).toEqual({})
end)
