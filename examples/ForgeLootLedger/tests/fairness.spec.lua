-- Award announcements, item and player tooltips, /forgeloot tally and spec.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local TOME = "|cffa335ee|Hitem:21281:0:0:0:0:0:0:0:60|h[Grimoire of Shadow Bolt]|h|r"
local TOKEN = "|cffa335ee|Hitem:47242:0:0:0:0:0:0:0:80|h[Weiheabzeichen des Kreuzzugs]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.item(21281, { name = "Grimoire of Shadow Bolt", link = TOME, quality = 4 })
    forge.item(47242, { name = "Weiheabzeichen des Kreuzzugs", link = TOKEN, quality = 4 })
end)

local function db() return forge.saved("ForgeLootLedgerDB") end

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
    forge.slash("/forgeloot start")
    forge.roll("Alice", 70)
    forge.advance(31, 0.25)
    forge.clickText("RECORD AWARD")
    forge.closeLoot()
    expect(raidSaid("[Loot] " .. CREST .. " goes to Alice - main spec.")).toBe(true)
end)

test("a master-loot handout is announced once the loot message confirms it", function()
    forge.masterLoot({ "Tester", "Alice", "Bob" })
    forge.openLoot({ { id = 21281 } })
    forge.slash("/forgeloot start")
    forge.roll("Bob", 30, 1, 99)
    forge.advance(31, 0.25)
    forge.clickText("GIVE LOOT + RECORD")
    expect(raidSaid("[Loot] " .. TOME .. " goes to Bob - off spec.")).toBe(false)
    forge.advance(0.1)
    expect(raidSaid("[Loot] " .. TOME .. " goes to Bob - off spec.")).toBe(true)
    forge.closeLoot()
end)

test("corrections and trades are announced too", function()
    forge.slash("/forgeloot set 1 Cara")
    expect(raidSaid("[Loot] " .. CREST .. " goes to Cara - main spec (corrected).")).toBe(true)
    forge.openLoot({ { id = 47242 } })
    forge.slash("/forgeloot start")
    forge.roll("Alice", 50)
    forge.advance(31, 0.25)
    GiveMasterLoot(1, 1)                     -- the master looter keeps it for now
    forge.advance(0.1)
    forge.closeLoot()
    expect(raidSaid("[Loot] " .. TOKEN .. " goes to Tester - main spec.")).toBe(true)
    forge.trade("Alice", { TOKEN })
    expect(raidSaid("[Loot] " .. TOKEN .. " goes to Alice - main spec (traded).")).toBe(true)
end)

test("a held item counts for the roll winner until it is traded", function()
    forge.openLoot({ { id = 20513 } })
    forge.slash("/forgeloot start")
    forge.roll("Bob", 44)
    forge.advance(31, 0.25)
    GiveMasterLoot(1, 1)
    forge.advance(0.1)
    forge.closeLoot()
    expect(db().history[1].state).toBe("held")
    expect(db().history[1].winner).toBe("Bob")
    forge.slash("/forgeloot tally")
    expect(forge.chat()).toContain("ForgeLootLedger: Bob: 1 main spec, 1 off spec")
end)

test("/forgeloot tally lists who got counted items; a token alone does not count", function()
    expect(forge.chat()).toContain("ForgeLootLedger: Cara: 1 main spec, 0 off spec")
    for _, line in ipairs(forge.chat()) do
        expect(string.find(line, "ForgeLootLedger: Alice:", 1, true)).toBeNil()
    end
end)

test("/forgeloot spec moves an award to the other tally or out of it", function()
    forge.slash("/forgeloot spec 1 os")
    expect(db().history[4].spec).toBe("os")
    forge.slash("/forgeloot spec 1 none")
    expect(db().history[4].spec).toBeNil()
    expect(forge.chat()).toContain("ForgeLootLedger: award #1 counts for no tally.")
    forge.slash("/forgeloot spec 1 maybe")
    expect(forge.chat()).toContain("ForgeLootLedger: usage: /forgeloot spec <#> ms|os|none")
end)

test("hovering an award shows the item, the award and the player's items", function()
    forge.hover(forge.findText("#2  ", true))
    local lines, shown = forge.tooltip()
    expect(shown).toBe(true)
    expect(lines[1]).toBe("item:21281:0:0:0:0:0:0:0:60")
    expect(tooltipHas("Award #2: Bob (GIVEN)")).toBe(true)
    expect(tooltipHas("Roll 30, OS")).toBe(true)
    expect(tooltipHas("Bob this raid: 1 main spec, 1 off spec (tokens not counted)")).toBe(true)
    forge.hover(forge.findText("#2  ", true), true)
    local _, stillShown = forge.tooltip()
    expect(stillShown).toBe(false)
end)

test("hovering a group member shows what they got this raid", function()
    forge.hover(forge.findText("Alice"))
    expect(tooltipHas("Alice this raid: 0 main spec, 0 off spec (tokens not counted)")).toBe(true)
    expect(tooltipHas("  " .. TOKEN .. "  MS  (token)")).toBe(true)
end)

test("hovering a loot row shows the item tooltip", function()
    forge.openLoot({ { id = 20513 } })
    expect(forge.text("ForgeLootLedgerRow1")).toBe(CREST)
    forge.hover("ForgeLootLedgerRow1")
    expect(forge.tooltip()[1]).toBe("item:20513:0:0:0:0:0:0:0:80")
    forge.closeLoot()
end)
