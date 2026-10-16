-- The raid's roll rules: /rnd 100 main spec, /rnd 99 off spec, EP enhance
-- main spec to 1+X..100+X with X = min(EP, 50); main spec beats off spec; within a
-- spec the fewest items this raid wins (tokens excluded), then the roll.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local TOME = "|cffa335ee|Hitem:21281:0:0:0:0:0:0:0:60|h[Grimoire of Shadow Bolt]|h|r"
local TOKEN = "|cffa335ee|Hitem:47242:0:0:0:0:0:0:0:80|h[Weiheabzeichen des Kreuzzugs]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.item(21281, { name = "Grimoire of Shadow Bolt", link = TOME, quality = 4 })
    forge.item(47242, { name = "Weiheabzeichen des Kreuzzugs", link = TOKEN, quality = 4 })
end)

local function db() return forge.saved("RaidLedgerDB") end

local function sentTo(needle)
    for _, m in ipairs(forge.sent()) do
        if string.find(m.message, needle, 1, true) then return true end
    end
    return false
end

-- rollFor opens loot with one item, runs a roll with `rolls` = { {name, value, low, high}, ... }
-- and records the award for the prefilled winner (by hand, no master loot).
local function rollFor(id, rolls)
    forge.slash("/ledger clear")
    forge.openLoot({ { id = id } })
    forge.slash("/ledger start")
    for _, r in ipairs(rolls) do forge.roll(r[1], r[2], r[3], r[4]) end
    forge.advance(31, 0.25)
    forge.clickText("RECORD AWARD")
    forge.closeLoot()
    return db().history[1]
end

test("the roll announcement explains main spec, enhanced and off spec", function()
    forge.raid({ "Alice", "Bob", "Cara", "Dora" })
    forge.openLoot({ { id = 20513 } })
    forge.slash("/ledger start")
    expect(sentTo("/rnd now! 30 seconds. /rnd 100 main spec (enhanced: 1+X to 100+X, X up to 50), /rnd 99 off spec.")).toBe(true)
    forge.closeLoot()
end)

test("main spec beats off spec whatever the roll", function()
    local award = rollFor(20513, { { "Alice", 99, 1, 99 }, { "Bob", 3 } })
    expect(award.recipient).toBe("Bob")
    expect(award.spec).toBe("ms")
    expect(award.roll).toBe(3)
    expect(sentTo("won by Bob (3) - main spec, 0 items so far.")).toBe(true)
end)

test("EP enhance main spec by any X from 1 to 50 (1+X..100+X up to 51-150)", function()
    local award = rollFor(21281, {
        { "Alice", 140, 41, 140 },     -- X = 41: counts
        { "Bob", 139, 50, 149 },       -- X = 49: counts
        { "Eve", 101, 2, 101 },        -- X = 1: counts
        { "Cara", 160, 61, 160 },      -- above 51-150: ignored
        { "Dora", 108, 10, 108 },      -- not a 100-wide range (off spec cannot be enhanced): ignored
    })
    expect(award.recipient).toBe("Alice")
    expect(award.low).toBe(41)
    expect(award.high).toBe(140)
    local notes = {}
    for _, r in ipairs(award.rollLog) do notes[r.name] = r.note or "counted" end
    expect(notes).toEqual({ Alice = "counted", Bob = "counted", Eve = "counted", Cara = "61-160", Dora = "10-108" })
    expect(sentTo("won by Alice (140) - main spec 41-140, 0 items so far.")).toBe(true)
end)

test("within main spec the player with fewer items wins over a higher roll", function()
    -- Bob already has one main-spec item (the crest), Alice one too (the tome).
    local award = rollFor(20513, { { "Bob", 98 }, { "Cara", 4 } })
    expect(award.recipient).toBe("Cara")
    expect(sentTo("won by Cara (4) - main spec, 0 items so far.")).toBe(true)
    local log = award.rollLog
    expect(log[1].name).toBe("Cara")
    expect(log[2].name).toBe("Bob")
    expect(log[2].tally).toBe(1)
end)

test("off spec has its own tally", function()
    -- Bob, Alice and Cara each have one main-spec item but no off-spec item yet.
    local award = rollFor(20513, { { "Bob", 20, 1, 99 }, { "Dora", 10, 1, 99 } })
    expect(award.recipient).toBe("Bob")
    expect(award.spec).toBe("os")
    -- Now Bob has an off-spec item: Dora wins the next off-spec roll.
    award = rollFor(21281, { { "Bob", 90, 1, 99 }, { "Dora", 2, 1, 99 } })
    expect(award.recipient).toBe("Dora")
    expect(sentTo("won by Dora (2) - off spec, 0 items so far.")).toBe(true)
end)

test("tokens do not count in the tally", function()
    local award = rollFor(47242, { { "Eve", 50 } })
    expect(award.recipient).toBe("Eve")
    expect(award.token).toBe(true)
    -- The token does not count: Eve has 0 main-spec items and beats Bob (1 item).
    award = rollFor(20513, { { "Bob", 99 }, { "Eve", 5 } })
    expect(award.recipient).toBe("Eve")
end)

test("tokens have their own tally: fewest tokens first", function()
    -- Eve has 1 main-spec token, Bob has main-spec items but no token.
    local award = rollFor(47242, { { "Eve", 99 }, { "Bob", 5 } })
    expect(award.recipient).toBe("Bob")
    expect(award.token).toBe(true)
    expect(sentTo("won by Bob (5) - main spec, 0 tokens so far.")).toBe(true)
    local log = award.rollLog
    expect(log[1].name).toBe("Bob")
    expect(log[2].name).toBe("Eve")
    expect(log[2].tally).toBe(1)
end)

test("a tie needs the same spec, tally and roll", function()
    forge.slash("/ledger newraid confirm")
    forge.slash("/ledger clear")
    forge.openLoot({ { id = 20513 } })
    forge.slash("/ledger start")
    forge.roll("Alice", 97)
    forge.roll("Bob", 97, 1, 99)          -- same number, but off spec
    forge.advance(31, 0.25)
    expect(sentTo("won by Alice (97) - main spec, 0 items so far.")).toBe(true)
    forge.closeLoot()
end)

test("removed awards do not count and a new raid resets the tally", function()
    forge.slash("/ledger newraid confirm")
    local first = rollFor(20513, { { "Alice", 50 } })
    forge.slash("/ledger del " .. first.id)
    local award = rollFor(21281, { { "Alice", 40 }, { "Bob", 30 } })
    expect(award.recipient).toBe("Alice")   -- her first item was removed: still 0
    forge.slash("/ledger newraid confirm")
    award = rollFor(20513, { { "Alice", 60 }, { "Bob", 30 } })
    expect(award.recipient).toBe("Alice")   -- new raid: everyone back to 0
end)

test("the export carries spec and roll range for the website", function()
    forge.slash("/ledger newraid confirm")
    rollFor(20513, { { "Alice", 130, 31, 130 } })
    rollFor(21281, { { "Bob", 12, 1, 99 } })
    forge.slash("/ledger raid 9")
    forge.slash("/ledger export")
    local text = forge.text("RaidLedgerExportText")
    expect(text).toContain(";20513;Alice;manual;130;ms;31-130;Alice")
    expect(text).toContain(";21281;Bob;manual;12;os;1-99;Bob")
end)
