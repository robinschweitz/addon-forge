-- FR-RL-029: a sync passes on the awards of ledgers that are not in the group.
-- FR-RL-030: SHARE in VERLAUF sends a finished raid; receivers keep it.
-- User report 2026-11-07: Kühlesauge recorded Monday's 37 awards and was not
-- online, so Kleinermagus's ledger answered Kleinbutoho's sync with one item.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"

local function record(id, origin, recipient, at)
    return { id = id, rev = 1, at = at, time = "20:00", item = CREST, itemID = 20513, recipient = recipient,
        state = "given", confirmed = true, spec = "ms", roll = 50, low = 1, high = 100, winner = recipient,
        origin = origin, rollLog = { { name = recipient, value = 50, low = 1, high = 100, round = 1, kind = "ms", tally = 0 } } }
end

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.setSaved("RaidLedgerDB", {
        session = "Kuehl-1793643041", nextID = 10, startedAt = 1793643041,
        history = { record(3, "Tester", "Bob", 1793643300), record(2, "Kuehl", "Bob", 1793643200),
            record(1, "Kuehl", "Asker", 1793643100) },
        raids = { { session = "Kuehl-1793000000", recorder = "Kuehl", startedAt = 1793000000, raidID = 30,
            tallyAdjust = {}, closedAt = 1793010000,
            history = { record(7, "Kuehl", "Bob", 1793000300), record(6, "Kuehl", "Asker", 1793000200),
                record(5, "Tester", "Bob", 1793000100) } } },
    })
end)

local function db() return forge.saved("RaidLedgerDB") end

local function receive(message, sender)
    forge.fire("CHAT_MSG_ADDON", "FLLedger", message, "RAID", sender or "Bob")
end

local function sentSince(n, kind)
    local out = {}
    local all = forge.addonMessages()
    for i = n + 1, #all do
        if string.sub(all[i].message, 1, string.len(kind)) == kind then table.insert(out, all[i].message) end
    end
    return out
end

local function told(text)
    local n = 0
    for _, line in ipairs(forge.chat()) do
        if string.find(line, text, 1, true) then n = n + 1 end
    end
    return n
end

test("FR-RL-030 SHARE without a group sends nothing and says so", function()
    if not RaidLedgerFrame:IsShown() then forge.slash("/ledger") end
    forge.click("RaidLedgerTabButtonHistory")
    forge.click("RaidLedgerRaidRow1")
    forge.click("RaidLedgerRaidShare")
    forge.advance(2, 0.25)
    expect(#forge.addonMessages()).toBe(0)
    expect(told("not in a group")).toBe(1)
end)

test("FR-RL-029 a sync answer passes on the awards of a ledger that is not in the group", function()
    forge.raid({ "Asker", "Bob" })
    forge.advance(12, 0.25)                    -- the login sync and its answers go first
    local before = #forge.addonMessages()
    receive("Q;Kuehl-1793643041;Asker", "Asker")
    forge.advance(10, 0.25)
    local sent = table.concat(sentSince(before, "A;"), "\n")
    expect(sent).toContain("A;Kuehl-1793643041;Kuehl;1;")
    expect(sent).toContain("A;Kuehl-1793643041;Kuehl;2;")
    expect(sent).toContain("A;Kuehl-1793643041;Tester;3;")
end)

test("FR-RL-029 with Kühlesauge in the group, Kühlesauge's ledger answers for its awards", function()
    forge.raid({ "Asker", "Bob", "Kuehl" })
    forge.advance(5, 0.25)
    local before = #forge.addonMessages()
    receive("Q;Kuehl-1793643041;Asker", "Asker")
    forge.advance(10, 0.25)
    local sent = table.concat(sentSince(before, "A;"), "\n")
    expect(sent).toContain("A;Kuehl-1793643041;Tester;3;")
    expect(string.find(sent, ";Kuehl;1;", 1, true)).toBeNil()
    forge.raid({ "Asker", "Bob" })
end)

test("FR-RL-030 SHARE sends the saved raid's awards and logs, marked as finished", function()
    forge.advance(5, 0.25)
    local before = #forge.addonMessages()
    forge.click("RaidLedgerTabButtonHistory")
    forge.click("RaidLedgerRaidRow1")
    forge.click("RaidLedgerRaidShare")
    forge.advance(10, 0.25)
    local awards = sentSince(before, "A;Kuehl-1793000000;")
    expect(#awards).toBe(3)
    for _, line in ipairs(awards) do expect(string.sub(line, -2)).toBe(";2") end
    expect(#sentSince(before, "L;Kuehl-1793000000;")).toBe(3)
    expect(#db().history).toBe(3)              -- nothing changed here
    expect(#forge.layoutIssues(RaidLedgerFrame)).toBe(0)
    forge.sketch("history-share", RaidLedgerFrame)
end)

test("FR-RL-030 a shared raid is kept under VERLAUF in date order, told once, never offered", function()
    local popups, raids = #forge.popups(), #db().raids
    local line = "A;Zed-1792000000;Zed;4;1;1792000100;20513;;Bob;given;1;ms;40;1;100;Bob;1;;20:00;2"
    receive(line)
    receive("L;Zed-1792000000;Zed;4;1;1;Bob,40,1,100,1,,0")
    receive("A;Zed-1792000000;Zed;5;1;1792000200;20513;;Asker;given;1;os;30;1;100;Asker;1;;20:01;2")
    expect(#db().raids).toBe(raids + 1)
    expect(db().raids[2].session).toBe("Zed-1792000000")   -- older than Kuehl's saved raid
    expect(#db().raids[2].history).toBe(2)
    expect(#db().raids[2].history[2].rollLog).toBe(1)
    expect(db().session).toBe("Kuehl-1793643041")
    expect(#db().history).toBe(3)
    expect(#forge.popups()).toBe(popups)
    expect(told("Bob shared the raid of")).toBe(1)
end)

test("FR-RL-030 a shared raid that is our current raid joins it", function()
    receive("A;Kuehl-1793643041;Kuehl;9;1;1793643900;20513;;Asker;given;1;ms;40;1;100;Asker;1;;21:00;2")
    expect(#db().history).toBe(4)
end)

test("FR-RL-030 one sender adds at most 5 shared raids per login", function()
    local raids = #db().raids
    for i = 1, 7 do
        receive(string.format("A;Ann-%d;Ann;1;1;%d;20513;;Bob;given;1;ms;40;1;100;Bob;1;;20:00;2",
            1780000000 + i, 1780000000 + i), "Asker")
    end
    expect(#db().raids).toBe(raids + 5)
    expect(forge.errors()).toEqual({})
end)
