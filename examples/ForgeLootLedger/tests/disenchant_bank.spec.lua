-- Items nobody wants go to the disenchanter or the guild bank: they are handed
-- out like any award, count in nobody's tally and stay in the export.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local TOME = "|cffa335ee|Hitem:21281:0:0:0:0:0:0:0:60|h[Grimoire of Shadow Bolt]|h|r"
local BOOTS = "|cffa335ee|Hitem:20514:0:0:0:0:0:0:0:60|h[Abyssal Boots]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.item(21281, { name = "Grimoire of Shadow Bolt", link = TOME, quality = 4 })
    forge.item(20514, { name = "Abyssal Boots", link = BOOTS, quality = 4 })
end)

local function db() return forge.saved("ForgeLootLedgerDB") end

local function raidSaid(text)
    for _, m in ipairs(forge.sent()) do
        if m.message == text then return true end
    end
    return false
end

test("DE hands the item to the enchanter named in the box; it counts for nobody", function()
    forge.raid({ "Tester", "Alice", "Bob" })
    forge.masterLoot({ "Tester", "Alice", "Bob" })
    forge.openLoot({ { id = 20513 }, { id = 21281 }, { id = 20514 } })
    forge.slash("/forgeloot start")
    forge.roll("Alice", 40)             -- someone rolled, but the raid lead disenchants it
    forge.advance(31, 0.25)
    forge.clickText("Bob")
    forge.click("ForgeLootLedgerDisenchant")
    expect(forge.awards()[1].candidate).toBe("Bob")
    local record = db().history[1]
    expect(record.state).toBe("disenchanted")
    expect(record.recipient).toBe("Bob")
    expect(record.spec).toBeNil()
    forge.advance(0.1)
    expect(record.confirmed).toBe(true)
    expect(raidSaid("[Loot] " .. CREST .. " will be disenchanted (Bob).")).toBe(true)
    expect(forge.findText("DISENCHANT")).toBeTruthy()
end)

test("BANK without a name keeps the item with the master looter for the guild bank", function()
    forge.click("ForgeLootLedgerRow1")
    forge.click("ForgeLootLedgerBank")
    forge.advance(0.1)
    local record = db().history[1]
    expect(record.state).toBe("bank")           -- not "held": the item is not waiting for a trade
    expect(record.recipient).toBe("Tester")
    expect(record.item).toBe(BOOTS)
    expect(raidSaid("[Loot] " .. BOOTS .. " goes to the guild bank (Tester).")).toBe(true)
end)

test("neither counts in a tally; a normal award still does", function()
    forge.click("ForgeLootLedgerRow1")
    forge.slash("/forgeloot start")
    forge.roll("Bob", 70)
    forge.advance(31, 0.25)
    forge.clickText("GIVE + RECORD")
    forge.advance(0.1)
    forge.closeLoot()
    forge.slash("/forgeloot tally")
    local chat = forge.chat()
    expect(chat).toContain("ForgeLootLedger: Bob: 1 main spec, 0 off spec")
    for _, line in ipairs(chat) do
        expect(string.find(line, "Tester:", 1, true)).toBeNil()
    end
end)

test("an existing award can be turned into DE; the export keeps the state", function()
    forge.click(forge.findText("#3  ", true))          -- Bob's tome
    forge.click("ForgeLootLedgerDisenchant")
    local record = db().history[1]
    expect(record.state).toBe("disenchanted")
    expect(record.spec).toBeNil()
    forge.slash("/forgeloot raid 7")
    forge.slash("/forgeloot export")
    local text = forge.text("ForgeLootLedgerExportText")
    expect(text).toContain(";20513;Bob;disenchanted;-;-;-;-")
    expect(text).toContain(";20514;Tester;bank;-;-;-;-")
    expect(text).toContain(";21281;Bob;disenchanted;-;-;-;-")
    forge.slash("/forgeloot tally")
    expect(forge.chat()).toContain("ForgeLootLedger: no items counted this raid yet.")
end)

test("the shared ledger carries both states to other ledgers", function()
    local found = {}
    for _, m in ipairs(forge.addonMessages()) do
        local state = string.match(m.message, "^A;[^;]*;Tester;%d+;%d+;%d+;%d*;[^;]*;[^;]*;([a-z]+);")
        if state then found[state] = true end
    end
    expect(found.disenchanted).toBe(true)
    expect(found.bank).toBe(true)
    expect(#forge.errors()).toBe(0)
end)
