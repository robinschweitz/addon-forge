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
