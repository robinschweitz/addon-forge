-- Manual corrections and the RS2 website export.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local TOME = "|cffa335ee|Hitem:21281:0:0:0:0:0:0:0:60|h[Grimoire of Shadow Bolt]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.item(21281, { name = "Grimoire of Shadow Bolt", link = TOME, quality = 4 })
end)

local function db() return forge.saved("ForgeLootLedgerDB") end

local function exportLines()
    local lines = {}
    for line in string.gmatch(forge.text("ForgeLootLedgerExportText") .. "\n", "([^\n]*)\n") do
        if line ~= "" then table.insert(lines, line) end
    end
    return lines
end

local function awardByHand(id, name)
    forge.openLoot({ { id = id } })
    forge.clickText(name)
    forge.clickText("RECORD AWARD")
    forge.closeLoot()
end

test("without master loot an award is recorded by hand", function()
    forge.party({ "Alice", "Bob" })
    awardByHand(20513, "Alice")
    awardByHand(21281, "Bob")
    expect(db().history[1].recipient).toBe("Bob")
    expect(db().history[1].state).toBe("manual")
    expect(db().history[1].id).toBe(2)
    expect(db().history[2].id).toBe(1)
end)

test("/forgeloot set changes the recipient by award number", function()
    forge.slash("/forgeloot set 1 Cara")
    expect(db().history[2].recipient).toBe("Cara")
    expect(db().history[2].state).toBe("manual")
    expect(forge.findText("Award #1 now goes to Cara.")).toBeTruthy()
end)

test("/forgeloot set without a name uses the targeted player", function()
    forge.unit("target", { name = "Dora", isPlayer = true })
    forge.slash("/forgeloot set #2")
    expect(db().history[1].recipient).toBe("Dora")
    forge.unit("target", false)
    forge.slash("/forgeloot set 2")
    expect(db().history[1].recipient).toBe("Dora")
    expect(forge.chat()).toContain("give a name or target the recipient.")
end)

test("clicking an award in the list lets you change its recipient", function()
    forge.click(forge.findText("#1  ", true))
    expect(forge.findText("CHANGE RECIPIENT")).toBeTruthy()
    forge.clickText("Bob")
    forge.clickText("CHANGE RECIPIENT")
    expect(db().history[2].recipient).toBe("Bob")
    expect(forge.findText("RECORD AWARD")).toBeTruthy()
end)

test("/forgeloot del removes an award but keeps it greyed out in the list", function()
    forge.slash("/forgeloot del 2")
    expect(db().history[1].state).toBe("deleted")
    expect(forge.findText("REMOVED")).toBeTruthy()
    forge.slash("/forgeloot del 2")
    expect(forge.chat()).toContain("no award #2.")
    forge.slash("/forgeloot set 99 Bob")
    expect(forge.chat()).toContain("no award #99.")
end)

test("the export needs the website raid ID first", function()
    forge.slash("/forgeloot export")
    expect("ForgeLootLedgerExportPanel").toBeShown()
    expect(forge.text("ForgeLootLedgerExportText")).toBe("")
    expect(forge.findText("Enter the website's raid ID to build the export.")).toBeTruthy()
end)

test("the RS2 export lists every award oldest first, with deleted ones as tombstones", function()
    forge.slash("/forgeloot raid 42")
    local lines = exportLines()
    local d = db()
    expect(lines[1]).toBe(string.format("RS2;LOOT;42;Tester;%d;%d", d.startedAt, time()))
    expect(lines[2]).toBe(string.format("1;%d;-;20513;Bob;manual;-", d.history[2].at))
    expect(lines[3]).toBe(string.format("2;%d;-;21281;Dora;deleted;-", d.history[1].at))
    expect(#lines).toBe(3)
    expect(forge.layoutIssues("ForgeLootLedgerFrame")).toEqual({})
end)

test("names cannot break the export", function()
    forge.slash("/forgeloot set 1 Evil|;Name")
    forge.slash("/forgeloot export")
    forge.slash("/forgeloot export")
    expect(exportLines()[2]).toContain(";EvilName;manual;")
end)

test("the raid ID and ledger survive /reload", function()
    forge.reload()
    expect(db().raidID).toBe(42)
    expect(db().nextID).toBe(2)
    forge.slash("/forgeloot export")
    expect(exportLines()[1]).toContain("RS2;LOOT;42;Tester;")
end)

test("a new raid empties the ledger and forgets the raid ID; award numbers keep counting", function()
    forge.slash("/forgeloot newraid")
    expect(forge.popups()[1].which).toBe("FORGELOOTLEDGER_NEW_RAID")
    StaticPopupDialogs["FORGELOOTLEDGER_NEW_RAID"].OnAccept()
    expect(#db().history).toBe(0)
    expect(db().raidID).toBeNil()
    expect(forge.text("ForgeLootLedgerExportText")).toBe("")
    forge.clickText("BACK")
    expect("ForgeLootLedgerExportPanel").toBeHidden()
    forge.party({ "Alice", "Bob" })
    awardByHand(20513, "Alice")
    expect(db().history[1].id).toBe(3)
end)
