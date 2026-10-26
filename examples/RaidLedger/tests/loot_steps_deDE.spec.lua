-- BEUTE in two steps on a German client (examples/RaidLedger-requirements.md
-- FR-RL-006 to FR-RL-009, window feedback 2026-10-26): the next step is
-- highlighted, every item can be handed out, the disenchanter belongs to the
-- raid, and VERGABEN only corrects.
local LION = "|cff1eff00|Hitem:15052:0:0:0:0:0:0:0:40|h[Löwenfellrüstung]|h|r"
local ROBE = "|cffa335ee|Hitem:21281:0:0:0:0:0:0:0:60|h[Robe des unerschütterlichen Wächters]|h|r"
local NAMES = { "Tester", "Schattenklinge", "Seelenfänger", "Runenwächterin", "Donnerfaust" }

before_load(function()
    forge.locale("deDE", { RANDOM_ROLL_RESULT = "%1$s würfelt. Ergebnis: %2$d (%3$d-%4$d)" })
    forge.item(15052, { name = "Löwenfellrüstung", link = LION, quality = 2 })
    forge.item(21281, { name = "Robe des unerschütterlichen Wächters", link = ROBE, quality = 4 })
end)

local function db() return forge.saved("RaidLedgerDB") end

-- The next step's button is green (ns.setPrimary).
local function primary(name)
    local _, g = forge.frame(name):GetBackdropColor()
    return g > 0.4
end

local function enabled(name) return forge.frame(name):IsEnabled() and true or false end

test("FR-RL-006 before a roll ROLL is the next step; a won roll names its winner on the give button", function()
    forge.raid(NAMES)
    forge.masterLoot(NAMES)
    forge.unit("target", { name = "Templer", guid = "0xF130003B69000101", dead = true, isPlayer = false })
    forge.openLoot({ { id = 21281 } })
    expect(forge.findText("Noch nicht gewürfelt. Weiter: würfeln.")).toBeTruthy()
    expect(primary("RaidLedgerStart")).toBe(true)
    expect(forge.text("RaidLedgerAward")).toBe("VERGEBEN AN ...")
    expect(enabled("RaidLedgerAward")).toBe(false)
    expect(forge.shown("RaidLedgerFreeRoll")).toBe(false)     -- not bind on equip
    forge.slash("/ledger start")
    forge.roll("Schattenklinge", 88)
    forge.advance(31, 0.25)
    expect(forge.findText("Schattenklinge hat gewonnen (88). Weiter: vergeben.")).toBeTruthy()
    expect(forge.text("RaidLedgerAward")).toBe("VERGEBEN AN SCHATTENKLINGE")
    expect(primary("RaidLedgerAward")).toBe(true)
    expect(primary("RaidLedgerStart")).toBe(false)
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
    forge.sketch("steps-winner", "RaidLedgerFrame")
    forge.click("RaidLedgerAward")
    expect(db().history[1].recipient).toBe("Schattenklinge")
    forge.closeLoot()
end)

test("FR-RL-008 the disenchanter is rolled from the raid bar, without a selected item", function()
    expect(forge.findText("ENTZAUBERER: -")).toBeTruthy()
    forge.click("RaidLedgerDisenchanterRoll")
    forge.roll("Runenwächterin", 64)
    forge.advance(31, 0.25)
    expect(forge.findText("ENTZAUBERER: Runenwächterin")).toBeTruthy()
    expect(forge.text("RaidLedgerDisenchanterRoll")).toBe("NOCHMAL WÜRFELN")
end)

-- The screenshot of 2026-10-26: an open item whose roll nobody took offered
-- only ROLL AGAIN.
test("FR-RL-007 an open item nobody rolled on is disenchanted from BEUTE", function()
    forge.unit("target", { name = "Templer", guid = "0xF130003B69000102", dead = true, isPlayer = false })
    forge.openLoot({ { id = 15052 } })
    forge.type("RaidLedgerRecipient", "Donnerfaust")
    forge.click("RaidLedgerPark")
    forge.advance(0.1)
    forge.closeLoot()
    expect(forge.findText("OFFENE ITEMS (1)")).toBeTruthy()
    forge.click(forge.findText(LION))
    expect(forge.findText("Offen: Donnerfaust hat es. Weiter: würfeln oder unten vergeben.")).toBeTruthy()
    forge.click("RaidLedgerStart")
    forge.advance(31, 0.25)                          -- nobody rolled
    expect(forge.findText("Wollte niemand. Weiter: entzaubern (oder Gildenbank, nochmal würfeln).")).toBeTruthy()
    expect(enabled("RaidLedgerDisenchant")).toBe(true)
    expect(primary("RaidLedgerDisenchant")).toBe(true)
    expect(enabled("RaidLedgerBank")).toBe(true)
    expect(enabled("RaidLedgerPark")).toBe(true)
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
    forge.sketch("steps-nobody", "RaidLedgerFrame")
    forge.click("RaidLedgerDisenchant")
    local record = db().history[1]
    expect(record.item).toBe(LION)
    expect(record.state).toBe("disenchanted")
    expect(record.recipient).toBe("Runenwächterin")
    expect(record.holder).toBe("Donnerfaust")
    expect(forge.findText("OFFENE ITEMS (1)")).toBeNil()
    expect(forge.findText(LION)).toBeNil()
end)

test("FR-RL-007 an open item that was not rolled goes to the guild bank from BEUTE", function()
    forge.unit("target", { name = "Templer", guid = "0xF130003B69000103", dead = true, isPlayer = false })
    forge.openLoot({ { id = 15052 } })
    forge.click("RaidLedgerPark")                    -- kept by Tester
    forge.advance(0.1)
    forge.closeLoot()
    forge.click(forge.findText(LION))
    expect(primary("RaidLedgerStart")).toBe(true)
    forge.sketch("steps-open", "RaidLedgerFrame")
    forge.click("RaidLedgerBank")
    expect(db().history[1].state).toBe("bank")
    expect(db().history[1].recipient).toBe("Tester")
    expect(forge.findText("OFFENE ITEMS (1)")).toBeNil()
end)

test("FR-RL-009 VERGABEN only corrects: no park, DE or bank button", function()
    forge.click("RaidLedgerTabButtonAwards")
    forge.click(forge.findText("#1  ", true))
    expect(forge.frame("RaidLedgerAwardDE")).toBeNil()
    expect(forge.frame("RaidLedgerAwardBank")).toBeNil()
    expect(forge.text("RaidLedgerAwardPark")).toBe("ZURÜCK IN BEUTE")
    expect(forge.findText("PARKEN")).toBeNil()
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
    forge.sketch("awards-corrections", "RaidLedgerFrame")
    forge.click("RaidLedgerAwardPark")
    expect(db().history[3].state).toBe("parked")
    expect(forge.findText("OFFENE ITEMS (1)")).toBeTruthy()   -- BEUTE is shown again
end)

local function sentAs(prefix)
    local last
    for _, m in ipairs(forge.sent()) do
        if string.find(m.message, prefix, 1, true) then last = m.chatType end
    end
    return last
end

test("FR-RL-010 an assistant announces roll starts and tie-breaks as raid warnings", function()
    forge.raid({ { name = "Tester", rank = 1 }, "Schattenklinge", "Seelenfänger", "Runenwächterin", "Donnerfaust" })
    forge.masterLoot(NAMES)
    forge.unit("target", { name = "Templer", guid = "0xF130003B69000104", dead = true, isPlayer = false })
    forge.openLoot({ { id = 21281 } })
    forge.slash("/ledger start")
    expect(sentAs("jetzt /rnd!")).toBe("RAID_WARNING")
    forge.roll("Schattenklinge", 50)
    forge.roll("Seelenfänger", 50)
    forge.advance(31, 0.25)
    expect(sentAs("Gleichstand zwischen")).toBe("RAID_WARNING")
    forge.roll("Schattenklinge", 70)
    forge.advance(16, 0.25)
    expect(sentAs("gewonnen von Schattenklinge")).toBe("RAID")   -- the winner goes to raid chat
    forge.click("RaidLedgerAward")
    forge.closeLoot()
end)

test("FR-RL-010 a raid member without rank announces in raid chat", function()
    forge.raid({ "Tester", "Schattenklinge", "Seelenfänger", "Runenwächterin", "Donnerfaust" })
    forge.unit("target", { name = "Templer", guid = "0xF130003B69000105", dead = true, isPlayer = false })
    forge.openLoot({ { id = 21281 } })
    forge.slash("/ledger start")
    expect(sentAs("jetzt /rnd!")).toBe("RAID")
    forge.advance(31, 0.25)
    forge.closeLoot()
    forge.slash("/ledger clear")
end)

test("FR-RL-011 WÄHLEN makes a raid member the disenchanter without a roll", function()
    forge.click("RaidLedgerDisenchanterChoose")
    expect("RaidLedgerMembers").toBeShown()
    forge.click(forge.findText("Donnerfaust"))
    expect(db().disenchanter).toBe("Donnerfaust")
    expect(forge.findText("ENTZAUBERER: Donnerfaust")).toBeTruthy()
    expect(sentAs("Donnerfaust ist der Entzauberer dieses Raids.")).toBe("RAID")
    expect(forge.text("RaidLedgerRecipient")).toBe("")       -- the box is left alone
    forge.slash("/ledger de Seelenfänger")
    expect(db().disenchanter).toBe("Seelenfänger")
end)

test("FR-RL-012 SPÄTER WÜRFELN sits in step 1 and hands the item to the name in the box", function()
    forge.unit("target", { name = "Templer", guid = "0xF130003B69000106", dead = true, isPlayer = false })
    forge.openLoot({ { id = 21281 } })
    expect(forge.text("RaidLedgerPark")).toBe("SPÄTER WÜRFELN")
    expect(forge.rect("RaidLedgerPark").top).toBe(forge.rect("RaidLedgerStart").top)
    forge.type("RaidLedgerRecipient", "Runenwächterin")
    forge.click("RaidLedgerPark")
    forge.advance(0.1)
    expect(db().history[1].state).toBe("parked")
    expect(db().history[1].recipient).toBe("Runenwächterin")
    forge.closeLoot()
end)

-- Both rows of step 2 end where step 1 ends; step 1 and 2 start at one x.
local function aligned()
    local start, de, bank, give = forge.rect("RaidLedgerStart"), forge.rect("RaidLedgerDisenchant"),
        forge.rect("RaidLedgerBank"), forge.rect("RaidLedgerAward")
    local right = forge.rect(forge.shown("RaidLedgerFreeRoll") and "RaidLedgerFreeRoll" or "RaidLedgerPark").right
    expect(de.left).toBe(start.left)
    expect(give.right).toBe(right)
    expect(bank.right).toBe(right)
end

test("FR-RL-013 the steps share one grid, at the default size and wider", function()
    forge.click(forge.findText(ROBE))                -- the open item: no free BoE roll
    aligned()
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
    forge.sketch("steps-grid", "RaidLedgerFrame")
    forge.drag("RaidLedgerResize", 200, -60)
    forge.advance(0.1)
    aligned()
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
    forge.sketch("steps-grid-wide", "RaidLedgerFrame")
    forge.slash("/ledger reset")
end)
