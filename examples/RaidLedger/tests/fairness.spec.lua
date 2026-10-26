-- Award announcements, item and player tooltips, /ledger tally and spec.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local TOME = "|cffa335ee|Hitem:21281:0:0:0:0:0:0:0:60|h[Grimoire of Shadow Bolt]|h|r"
local TOKEN = "|cffa335ee|Hitem:47242:0:0:0:0:0:0:0:80|h[Weiheabzeichen des Kreuzzugs]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.item(21281, { name = "Grimoire of Shadow Bolt", link = TOME, quality = 4 })
    forge.item(47242, { name = "Weiheabzeichen des Kreuzzugs", link = TOKEN, quality = 4 })
end)

local function db() return forge.saved("RaidLedgerDB") end

local function raidSaid(text)
    for _, m in ipairs(forge.sent()) do
        if m.chatType == "RAID" and m.message == text then return true end
    end
    return false
end

local function tooltipHas(needle)
    local lines = forge.tooltip()
    for _, line in ipairs(lines) do
        if string.find(line, needle, 1, true) then return true end
    end
    return false
end

test("a hand-recorded award is announced to the raid", function()
    forge.raid({ "Alice", "Bob" })
    forge.openLoot({ { id = 20513 } })
    forge.slash("/ledger start")
    forge.roll("Alice", 70)
    forge.advance(31, 0.25)
    forge.clickText("RECORD AWARD")
    forge.closeLoot()
    expect(raidSaid("[Loot] " .. CREST .. " goes to Alice - main spec.")).toBe(true)
end)

test("a master-loot handout is announced once the loot message confirms it", function()
    forge.masterLoot({ "Tester", "Alice", "Bob" })
    forge.openLoot({ { id = 21281 } })
    forge.slash("/ledger start")
    forge.roll("Bob", 30, 1, 99)
    forge.advance(31, 0.25)
    forge.clickText("GIVE + RECORD")
    expect(raidSaid("[Loot] " .. TOME .. " goes to Bob - off spec.")).toBe(false)
    forge.advance(0.1)
    expect(raidSaid("[Loot] " .. TOME .. " goes to Bob - off spec.")).toBe(true)
    forge.closeLoot()
end)

test("corrections and hand-overs are announced too", function()
    forge.slash("/ledger set 1 Cara")
    expect(raidSaid("[Loot] " .. CREST .. " goes to Cara - main spec (corrected).")).toBe(true)
    forge.openLoot({ { id = 47242 } })
    forge.slash("/ledger start")
    forge.roll("Alice", 50)
    forge.advance(31, 0.25)
    GiveMasterLoot(1, 1)                     -- the master looter keeps it for now
    forge.advance(0.1)
    forge.closeLoot()
    -- The raid hears who won it, and who hands it over (user request 2026-10-23).
    expect(raidSaid("[Loot] " .. TOKEN .. " goes to Alice - main spec (Tester hands it over).")).toBe(true)
    expect(raidSaid("[Loot] " .. TOKEN .. " goes to Tester - main spec.")).toBe(false)
end)

test("an item the master looter keeps counts for its roll winner", function()
    forge.openLoot({ { id = 20513 } })
    forge.slash("/ledger start")
    forge.roll("Bob", 44)
    forge.advance(31, 0.25)
    GiveMasterLoot(1, 1)
    forge.advance(0.1)
    forge.closeLoot()
    expect(db().history[1].recipient).toBe("Bob")
    expect(db().history[1].winner).toBe("Bob")
    forge.slash("/ledger tally")
    expect(forge.chat()).toContain("RaidLedger: Bob: 1 main spec, 1 off spec")
end)

test("/ledger tally keeps items and tokens in separate lists", function()
    expect(forge.chat()).toContain("RaidLedger: Cara: 1 main spec, 0 off spec")
    expect(forge.chat()).toContain("RaidLedger: tokens this raid:")
    expect(forge.chat()).toContain("RaidLedger: Alice: 1 main spec, 0 off spec (tokens)")
    for _, line in ipairs(forge.chat()) do
        -- Alice only got a token: she is not in the item list.
        expect(string.find(line, "RaidLedger: Alice: 0 main spec", 1, true)).toBeNil()
    end
end)

test("/ledger spec moves an award to the other tally or out of it", function()
    forge.slash("/ledger spec 1 os")
    expect(db().history[4].spec).toBe("os")
    forge.slash("/ledger spec 1 none")
    expect(db().history[4].spec).toBeNil()
    expect(forge.chat()).toContain("RaidLedger: award #1 counts for no tally.")
    forge.slash("/ledger spec 1 maybe")
    expect(forge.chat()).toContain("RaidLedger: usage: /ledger spec <#> ms|os|none")
end)

test("hovering an award shows the item, the award and the player's items", function()
    forge.click("RaidLedgerTabButtonAwards")
    forge.hover(forge.findText("#2  ", true))
    local lines, shown = forge.tooltip()
    expect(shown).toBe(true)
    expect(lines[1]).toBe("item:21281:0:0:0:0:0:0:0:60")
    expect(tooltipHas("Award #2: Bob (GIVEN)")).toBe(true)
    expect(tooltipHas("Roll 30, OS")).toBe(true)
    expect(tooltipHas("Bob this raid: items 1 MS / 1 OS, tokens 0 MS / 0 OS")).toBe(true)
    forge.hover(forge.findText("#2  ", true), true)
    local _, stillShown = forge.tooltip()
    expect(stillShown).toBe(false)
end)

test("hovering a player in the tally shows what they got this raid", function()
    forge.click("RaidLedgerTabButtonTally")
    forge.hover(forge.findText("Alice"))
    expect(tooltipHas("Alice this raid: items 0 MS / 0 OS, tokens 1 MS / 0 OS")).toBe(true)
    expect(tooltipHas("  " .. TOKEN .. "  MS  (token)")).toBe(true)
end)

test("hovering a loot row shows the item tooltip", function()
    forge.click("RaidLedgerTabButtonLoot")
    forge.openLoot({ { id = 20513 } })
    expect(forge.text("RaidLedgerItemRow1")).toBe(CREST)
    forge.hover("RaidLedgerItemRow1")
    expect(forge.tooltip()[1]).toBe("item:20513:0:0:0:0:0:0:0:80")
    forge.closeLoot()
end)
