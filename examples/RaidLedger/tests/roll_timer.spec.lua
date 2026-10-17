-- /ledger timer: users choose the roll and tie-break lengths; they are saved.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
end)

local function db() return forge.saved("RaidLedgerDB") end

local function said(needle)
    local count = 0
    for _, m in ipairs(forge.sent()) do
        if m.chatType == "RAID" and string.find(m.message, needle, 1, true) then count = count + 1 end
    end
    return count
end

local function startRoll()
    forge.slash("/ledger clear")
    forge.openLoot({ { id = 20513 } })
    forge.slash("/ledger start")
end

test("/ledger timer shows the defaults", function()
    forge.slash("/ledger timer")
    expect(forge.lastChat()).toBe("RaidLedger: roll timer: 30 seconds, tie-break: 15 seconds.")
end)

test("a longer timer is announced and the roll waits for it", function()
    forge.raid({ "Alice", "Bob" })
    forge.slash("/ledger timer 45")
    expect(forge.lastChat()).toBe("RaidLedger: roll timer: 45 seconds, tie-break: 15 seconds.")
    expect(db().rollSeconds).toBe(45)
    startRoll()
    expect(said("[Loot] " .. CREST .. " - /rnd now! 45 seconds.")).toBe(1)
    expect(forge.findText("45-second raid roll started.")).toBeTruthy()
    forge.roll("Alice", 60)
    forge.advance(31, 0.25)
    expect(said("won by")).toBe(0)
    -- Reminders at half and a quarter of the time: 23 and 11 seconds left.
    expect(said(CREST .. " - 23 seconds left.")).toBe(1)
    expect(said(CREST .. " - 11 seconds left.")).toBe(0)
    forge.advance(3, 0.25)
    expect(said(CREST .. " - 11 seconds left.")).toBe(1)
    expect(said("15 seconds left.")).toBe(0)
    forge.roll("Bob", 70)                      -- still in time
    forge.advance(12, 0.25)
    expect(said("won by Bob (70)")).toBe(1)
    forge.closeLoot()
end)

test("the roll start shared with the group carries the chosen time", function()
    local found = false
    for _, m in ipairs(forge.addonMessages()) do
        if string.sub(m.message, 1, 2) == "S;" and string.find(m.message, ";20513;45;1;", 1, true) then found = true end
    end
    expect(found).toBe(true)
end)

test("the tie-break length can be set on its own", function()
    forge.slash("/ledger timer tie 20")
    expect(forge.lastChat()).toBe("RaidLedger: roll timer: 45 seconds, tie-break: 20 seconds.")
    startRoll()
    forge.roll("Alice", 50)
    forge.roll("Bob", 50)
    forge.advance(46, 0.25)
    expect(said("tie between Alice and Bob (50)! Alice, Bob: /rnd again, 20 seconds.")).toBe(1)
    forge.roll("Alice", 10)
    forge.roll("Bob", 90)
    forge.advance(16, 0.25)
    -- The tie-break reminds at 10 and 5 seconds left too.
    expect(said(CREST .. " - 10 seconds left.")).toBe(1)
    expect(said(CREST .. " - 5 seconds left.")).toBe(1)
    expect(said("won by Bob (90)")).toBe(0)
    forge.advance(5, 0.25)
    expect(said("won by Bob (90)")).toBe(1)
    forge.closeLoot()
end)

test("a short timer reminds at half and a quarter of its time", function()
    forge.slash("/ledger timer 10 5")
    local before = said(" seconds left.")
    startRoll()
    forge.roll("Alice", 33)
    forge.advance(11, 0.25)
    expect(said(" seconds left.") - before).toBe(2)
    expect(said(CREST .. " - 5 seconds left.")).toBeGreaterThan(0)
    expect(said(CREST .. " - 3 seconds left.")).toBe(1)
    expect(said("won by Alice (33)")).toBe(1)
    forge.closeLoot()
end)

test("the timer survives /reload and a new raid", function()
    forge.reload()
    forge.slash("/ledger newraid confirm")
    forge.slash("/ledger timer")
    expect(forge.lastChat()).toBe("RaidLedger: roll timer: 10 seconds, tie-break: 5 seconds.")
end)

test("invalid lengths are refused and keep the setting", function()
    for _, bad in ipairs({ "5", "301", "abc", "30 2", "30 200", "12.5", "tie", "tie x", "1 2 3" }) do
        forge.slash("/ledger timer " .. bad)
        expect(forge.lastChat()).toBe("RaidLedger: usage: /ledger timer [seconds] [tie-break seconds] (roll 10-300, tie-break 5-120), or /ledger timer reset")
    end
    expect(db().rollSeconds).toBe(10)
    expect(db().tieSeconds).toBe(5)
end)

test("/ledger timer reset restores 30 and 15 seconds; help shows the current time", function()
    forge.slash("/ledger timer reset")
    expect(forge.lastChat()).toBe("RaidLedger: roll timer: 30 seconds, tie-break: 15 seconds.")
    expect(db().rollSeconds).toBeNil()
    forge.slash("/ledger timer 60")
    forge.slash("/ledger help")
    expect(forge.chat()).toContain("RaidLedger: /ledger start - start a 60 s /rnd roll for the selected item")
end)
