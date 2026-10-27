-- Manual corrections and the RS2 website export.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local TOME = "|cffa335ee|Hitem:21281:0:0:0:0:0:0:0:60|h[Grimoire of Shadow Bolt]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.item(21281, { name = "Grimoire of Shadow Bolt", link = TOME, quality = 4 })
end)

local function db() return forge.saved("RaidLedgerDB") end

local function exportLines()
    local lines = {}
    for line in string.gmatch(forge.text("RaidLedgerExportText") .. "\n", "([^\n]*)\n") do
        if line ~= "" then table.insert(lines, line) end
    end
    return lines
end

local function awardByHand(id, name)
    forge.click("RaidLedgerTabButtonLoot")
    forge.openLoot({ { id = id } })
    forge.type("RaidLedgerRecipient", name)
    forge.click("RaidLedgerAward")
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

test("/ledger set changes the recipient by award number", function()
    forge.slash("/ledger set 1 Cara")
    expect(db().history[2].recipient).toBe("Cara")
    expect(db().history[2].state).toBe("manual")
    expect(forge.findText("Award #1 now goes to Cara.")).toBeTruthy()
end)

test("/ledger set without a name uses the targeted player", function()
    forge.unit("target", { name = "Dora", isPlayer = true })
    forge.slash("/ledger set #2")
    expect(db().history[1].recipient).toBe("Dora")
    forge.unit("target", false)
    forge.slash("/ledger set 2")
    expect(db().history[1].recipient).toBe("Dora")
    expect(forge.chat()).toContain("give a name or target the recipient.")
end)

test("clicking an award in the list lets you change its recipient", function()
    forge.click("RaidLedgerTabButtonAwards")
    forge.click(forge.findText("#1  ", true))
    expect(forge.findText("CHANGE RECIPIENT")).toBeTruthy()
    expect(forge.text("RaidLedgerAwardRecipient")).toBe("Cara")
    forge.type("RaidLedgerAwardRecipient", "Bob")
    forge.clickText("CHANGE RECIPIENT")
    expect(db().history[2].recipient).toBe("Bob")
    expect(forge.findText("NOW: Bob", true)).toBeTruthy()
    expect(forge.findText("MANUAL", true)).toBeNil()
end)

test("/ledger del removes an award but keeps it greyed out in the list", function()
    forge.slash("/ledger del 2")
    expect(db().history[1].state).toBe("deleted")
    expect(forge.findText("REMOVED")).toBeTruthy()
    forge.slash("/ledger del 2")
    expect(forge.chat()).toContain("no award #2.")
    forge.slash("/ledger set 99 Bob")
    expect(forge.chat()).toContain("no award #99.")
end)

test("the export needs the website raid ID first", function()
    forge.slash("/ledger export")
    expect("RaidLedgerExportPanel").toBeShown()
    expect(forge.text("RaidLedgerExportText")).toBe("")
    expect(forge.findText("Enter the website's raid ID to build the export.")).toBeTruthy()
end)

test("the RS2 export lists every award oldest first, with deleted ones as tombstones", function()
    forge.slash("/ledger raid 42")
    local lines = exportLines()
    local d = db()
    expect(lines[1]).toBe(string.format("RS2;LOOT;42;Tester;%d;%d", d.startedAt, time()))
    expect(lines[2]).toBe(string.format("1;%d;-;20513;Bob;manual;-;-;-;-", d.history[2].at))
    expect(lines[3]).toBe(string.format("2;%d;-;21281;Dora;deleted;-;-;-;-", d.history[1].at))
    expect(#lines).toBe(3)
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
end)

test("names cannot break the export", function()
    forge.slash("/ledger set 1 Evil|;Name")
    forge.slash("/ledger export")
    forge.slash("/ledger export")
    expect(exportLines()[2]).toContain(";EvilName;manual;")
end)

test("the raid ID and ledger survive /reload", function()
    forge.reload()
    expect(db().raidID).toBe(42)
    expect(db().nextID).toBe(2)
    forge.slash("/ledger export")
    expect(exportLines()[1]).toContain("RS2;LOOT;42;Tester;")
end)

test("a new raid empties the ledger and forgets the raid ID; award numbers keep counting", function()
    forge.slash("/ledger newraid")
    expect(forge.popups()[1].which).toBe("RAIDLEDGER_NEW_RAID")
    StaticPopupDialogs["RAIDLEDGER_NEW_RAID"].OnAccept()
    expect(#db().history).toBe(0)
    expect(db().raidID).toBeNil()
    expect(forge.text("RaidLedgerExportText")).toBe("")
    forge.clickText("BACK")
    expect("RaidLedgerExportPanel").toBeHidden()
    forge.party({ "Alice", "Bob" })
    awardByHand(20513, "Alice")
    expect(db().history[1].id).toBe(3)
end)
