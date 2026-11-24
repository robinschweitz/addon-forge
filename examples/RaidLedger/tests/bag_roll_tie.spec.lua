-- Raid feedback 2026-11-17: "bei grünem Item, was aus der Tasche verrollt
-- wurde, wurde bei selbem Roll kein Stechen angesagt". A tie on a roll that
-- was started on a bag item must start a tie-break like a corpse roll.
local GREEN = "|cff1eff00|Hitem:9999:0:0:0:0:0:0:0:80|h[Grüner Testgürtel]|h|r"
local bags = {}

before_load(function()
    forge.item(9999, { name = "Grüner Testgürtel", link = GREEN, quality = 2 })
    bags = { [0] = { GREEN } }
    forge.stub("ContainerFrameItemButton_OnModifiedClick", function() end)
    forge.stub("GetContainerItemLink", function(bag, slot) return bags[bag] and bags[bag][slot] end)
    forge.stub("GetContainerNumSlots", function(bag) return bags[bag] and 16 or 0 end)
end)

local function sentTo(chatType, needle)
    for _, m in ipairs(forge.sent()) do
        if m.chatType == chatType and string.find(m.message, needle, 1, true) then return true end
    end
    return false
end

test("a tie on a green item rolled from the bags starts a tie-break", function()
    forge.raid({ "Tester", "Alice", "Bob" })
    forge.masterLoot({ "Tester", "Alice", "Bob" })
    forge.slash("/ledger roll 9999")
    forge.roll("Alice", 57)
    forge.roll("Bob", 57)
    forge.advance(31, 0.25)
    expect(sentTo("RAID_WARNING", "tie between Alice and Bob (57)") or sentTo("RAID", "tie between Alice and Bob (57)")).toBe(true)
    expect(sentTo("RAID", "goes to")).toBe(false)
    forge.roll("Alice", 10)
    forge.roll("Bob", 80)
    forge.advance(16, 0.25)
    expect(forge.saved("RaidLedgerDB").history[1].winner).toBe("Bob")
    expect(sentTo("RAID", "has more items")).toBe(false)
end)

test("FR-RL-036 the same roll lost on the item count is named in the announcement", function()
    -- Bob won the belt above; the same item is rolled again from the bags.
    local before = table.getn(forge.sent())
    local function saidSince(needle)
        for i = before + 1, table.getn(forge.sent()) do
            if string.find(forge.sent()[i].message, needle, 1, true) then return true end
        end
        return false
    end
    forge.slash("/ledger roll 9999")
    forge.roll("Bob", 57)
    forge.roll("Alice", 57)
    forge.advance(31, 0.25)
    expect(saidSince("tie between")).toBe(false)
    expect(saidSince("won by Alice (57)")).toBe(true)
    expect(saidSince("Bob (57) has more items this raid.")).toBe(true)
end)
