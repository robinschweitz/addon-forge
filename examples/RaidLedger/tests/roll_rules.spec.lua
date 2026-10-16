-- Loot rules decided by the user: the first /rnd counts, and ties go to a
-- tie-break announced to the group in which only the tied players may roll.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
end)

local function sentTo(chatType, needle)
    for _, m in ipairs(forge.sent()) do
        if m.chatType == chatType and string.find(m.message, needle, 1, true) then return true end
    end
    return false
end

test("a re-roll does not replace a player's first roll", function()
    forge.openLoot({ { id = 20513 } })
    forge.slash("/ledger start")
    forge.roll("Alice", 42)
    forge.roll("Bob", 50)
    forge.roll("Alice", 99)               -- re-roll: ignored
    forge.advance(31, 0.25)
    expect(forge.chat()).toContain("won by Bob (50)")
    forge.closeLoot()
    forge.slash("/ledger clear")
end)

test("a tie on the top roll starts a raid tie-break among the tied players only", function()
    forge.raid({ "Alice", "Bob", "Cara" })
    forge.openLoot({ { id = 20513 } })
    forge.slash("/ledger start")
    forge.roll("Alice", 97)
    forge.roll("Bob", 97)
    forge.roll("Cara", 20)
    forge.advance(31, 0.25)
    expect(sentTo("RAID", "tie between Alice and Bob (97)")).toBe(true)
    expect(sentTo("RAID", "won by")).toBe(false)
    forge.roll("Cara", 100)               -- not in the tie-break: ignored
    forge.roll("Alice", 12)
    forge.roll("Bob", 64)
    forge.advance(16, 0.25)
    expect(sentTo("RAID", "won by Bob (64)")).toBe(true)
end)

test("a tie-break can itself tie and repeats", function()
    forge.closeLoot()
    forge.slash("/ledger clear")
    forge.openLoot({ { id = 20513 } })
    forge.slash("/ledger start")
    forge.roll("Alice", 50)
    forge.roll("Bob", 50)
    forge.advance(31, 0.25)
    forge.roll("Alice", 33)
    forge.roll("Bob", 33)
    forge.advance(16, 0.25)
    forge.roll("Alice", 80)
    forge.roll("Bob", 5)
    forge.advance(16, 0.25)
    expect(sentTo("RAID", "won by Alice (80)")).toBe(true)
end)
