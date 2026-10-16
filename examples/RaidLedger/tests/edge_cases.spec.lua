-- Edge cases found in code review. Each test describes the intended behaviour.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local TOME = "|cffa335ee|Hitem:21281:0:0:0:0:0:0:0:60|h[Grimoire of Shadow Bolt]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.item(21281, { name = "Grimoire of Shadow Bolt", link = TOME, quality = 4 })
end)

local function sentTo(chatType, needle)
    for _, m in ipairs(forge.sent()) do
        if m.chatType == chatType and string.find(m.message, needle, 1, true) then return true end
    end
    return false
end

test("a running roll still finishes while the ledger window is hidden", function()
    forge.openLoot({ { id = 20513 } })
    forge.slash("/ledger start")
    forge.slash("/ledger")            -- hide the window mid-roll
    expect("RaidLedgerFrame").toBeHidden()
    forge.roll("Alice", 61)
    forge.advance(31, 0.25)
    expect(forge.chat()).toContain("won by Alice (61)")
    forge.slash("/ledger")
end)

test("an awarded item is not re-added while the loot window stays open", function()
    forge.clickText("RECORD AWARD")
    forge.advance(1, 0.25)              -- OnUpdate re-scans the still-open loot window
    expect(forge.findText(CREST)).toBeNil()
    expect(forge.saved("RaidLedgerDB").history[1].recipient).toBe("Alice")
    forge.closeLoot()
end)

test("new loot during a running roll does not steal its rolls", function()
    forge.openLoot({ { id = 20513 } })
    forge.slash("/ledger start")
    forge.closeLoot()
    forge.openLoot({ { id = 21281 } })  -- second corpse while the crest roll runs
    forge.roll("Bob", 77)
    forge.advance(31, 0.25)
    expect(forge.chat()).toContain("[Abyssal Crest]|h|r won by Bob (77)")
    expect(forge.findText(TOME)).toBeTruthy()   -- the new item is listed, not lost
    forge.closeLoot()
    forge.slash("/ledger clear")
end)

test("rolls outside 1-100 are ignored", function()
    forge.openLoot({ { id = 20513 } })
    forge.slash("/ledger start")
    forge.roll("Cheater", 999, 1, 1000)
    forge.roll("Honest", 40)
    forge.advance(31, 0.25)
    expect(forge.chat()).toContain("won by Honest (40)")
    forge.closeLoot()
    forge.slash("/ledger clear")
end)

test("in a party (not a raid) roll announcements reach the party", function()
    forge.party({ "Alice", "Bob" })
    forge.openLoot({ { id = 20513 } })
    forge.slash("/ledger start")
    expect(sentTo("PARTY", "/rnd now!")).toBe(true)
    forge.closeLoot()
    forge.slash("/ledger clear")
end)

test("raid announcements go to raid chat", function()
    forge.raid({ "Alice", "Bob", "Cara" })
    forge.openLoot({ { id = 20513 } })
    forge.slash("/ledger start")
    expect(sentTo("RAID", "/rnd now!")).toBe(true)
    forge.closeLoot()
end)
