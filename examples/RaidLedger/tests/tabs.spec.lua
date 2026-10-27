-- The tabbed window (UI feedback 2026-10-19: "cleaner, and everything in the
-- UI"): rolls start from BEUTE, awards are corrected in VERGABEN, the tally is
-- seen and corrected in SPIELER, and the old chat-only options live in
-- EINSTELLUNGEN.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local TOME = "|cffa335ee|Hitem:21281:0:0:0:0:0:0:0:60|h[Grimoire of Shadow Bolt]|h|r"
local BOE = "|cffa335ee|Hitem:45510:0:0:0:0:0:0:0:80|h[Cloak of Whispers]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.item(21281, { name = "Grimoire of Shadow Bolt", link = TOME, quality = 4 })
    forge.item(45510, { name = "Cloak of Whispers", link = BOE, quality = 4, tooltip = { "ITEM_BIND_ON_EQUIP" } })
end)

local function db() return forge.saved("RaidLedgerDB") end

local function raidSaid(text)
    for _, m in ipairs(forge.sent()) do
        if string.find(m.message, text, 1, true) then return true end
    end
    return false
end

local function tally()
    local before = #forge.chat()
    forge.slash("/ledger tally")
    local out = {}
    for i = before + 1, #forge.chat() do table.insert(out, forge.chat()[i]) end
    return table.concat(out, "\n")
end

local function tallyRow(name)
    for i = 1, 17 do
        local row = forge.frame("RaidLedgerTallyRow" .. i)
        if row and row:IsShown() and row.playerName == name then return row end
    end
end

test("the window opens on BEUTE with five tabs", function()
    forge.raid({ "Tester", "Alice", "Bob", "Cara" })
    for _, tab in ipairs({ "LOOT (0)", "AWARDS (0)", "TALLY", "RAID", "SETTINGS" }) do
        expect(forge.findText(tab)).toBeTruthy()
    end
    expect(forge.findText("Select an item on the left")).toBeTruthy()
    expect(forge.frame("RaidLedgerStart"):IsEnabled()).toBeFalsy()
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
end)

test("ROLL starts the roll from the window, no chat command needed", function()
    forge.openLoot({ { id = 20513 } })
    expect(forge.text("RaidLedgerItem")).toBe(CREST)             -- new loot is selected
    forge.click("RaidLedgerStart")
    expect(raidSaid("[Loot] " .. CREST .. " - /rnd now! 30 seconds.")).toBe(true)
    expect(forge.frame("RaidLedgerStart"):IsEnabled()).toBeFalsy()   -- no restart while it runs
    forge.roll("Alice", 60)
    forge.roll("Bob", 40, 1, 99)
    forge.advance(31, 0.25)
    expect(forge.text("RaidLedgerStart")).toBe("ROLL AGAIN")
    expect(forge.text("RaidLedgerRecipient")).toBe("Alice")
    forge.click("RaidLedgerAward")
    forge.closeLoot()
    expect(db().history[1].recipient).toBe("Alice")
end)

test("FREE BOE ROLL posts a free roll from the window", function()
    forge.openLoot({ { id = 45510 } })
    forge.click("RaidLedgerFreeRoll")
    expect(raidSaid("[Loot] " .. BOE .. " - free BoE roll for any character! /rnd 100, 30 seconds.")).toBe(true)
    forge.slash("/ledger clear")
    forge.closeLoot()
end)

test("VERGABEN: COUNTS AS moves an award between the tallies", function()
    forge.click("RaidLedgerTabButtonAwards")
    forge.clickText(string.format("#%d  %s  %s", db().history[1].id, db().history[1].time, CREST))
    expect(forge.findText("NOW: Alice  |  main spec  |  roll 60")).toBeTruthy()
    forge.click("RaidLedgerSpecos")
    expect(db().history[1].spec).toBe("os")
    expect(tally()).toContain("Alice: 0 main spec, 1 off spec")
    forge.click("RaidLedgerSpecnone")
    expect(db().history[1].spec).toBeNil()
    expect(tally()).toContain("no items counted this raid yet.")
    forge.click("RaidLedgerSpecms")
    expect(tally()).toContain("Alice: 1 main spec, 0 off spec")
end)

test("VERGABEN: REMOVE asks first; CHANGE RECIPIENT restores the award", function()
    forge.click("RaidLedgerRemove")
    local popups = forge.popups()
    expect(popups[#popups].which).toBe("RAIDLEDGER_REMOVE_AWARD")
    StaticPopupDialogs["RAIDLEDGER_REMOVE_AWARD"].OnAccept(nil, popups[#popups].data)
    expect(db().history[1].state).toBe("deleted")
    expect(forge.text("RaidLedgerChangeRecipient")).toBe("RESTORE + SET")
    expect(forge.frame("RaidLedgerRemove"):IsEnabled()).toBeFalsy()
    forge.type("RaidLedgerAwardRecipient", "Cara")
    forge.click("RaidLedgerChangeRecipient")
    expect(db().history[1].state).toBe("manual")
    expect(db().history[1].recipient).toBe("Cara")
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
end)

test("SPIELER lists the raid with items and tokens per spec", function()
    forge.click("RaidLedgerTabButtonTally")
    local cara = tallyRow("Cara")
    expect(cara).toBeTruthy()
    expect(forge.text(cara.columns[4])).toBe("1")   -- items MS
    expect(forge.text(cara.columns[3])).toBe("0")   -- items OS
    expect(tallyRow("Bob")).toBeTruthy()             -- in the raid, nothing yet
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
end)

test("- / + correct a player's tally; corrections are shared and rank the next roll", function()
    local before = #forge.addonMessages()
    forge.click(tallyRow("Bob"))
    expect(forge.findText("Bob", true)).toBeTruthy()
    forge.click("RaidLedgerTallyPlusms")
    forge.click("RaidLedgerTallyPlusms")
    forge.click("RaidLedgerTallyMinusms")
    expect(db().tallyAdjust.bob.ms).toBe(1)
    expect(tally()).toContain("Bob: 1 main spec, 0 off spec")
    expect(forge.text(tallyRow("Bob").columns[4])).toBe("1*")
    expect(forge.findText("1 (+1)")).toBeTruthy()
    forge.advance(5, 0.25)   -- after the queued award messages
    local shared
    for i = before + 1, #forge.addonMessages() do
        local m = forge.addonMessages()[i].message
        if string.sub(m, 1, 2) == "T;" then shared = m end
    end
    expect(shared).toContain(";Bob;1;0;0;0;")
    -- Bob and Cara now both have one item: the higher roll wins, not Bob's low one.
    forge.click("RaidLedgerTabButtonLoot")
    forge.openLoot({ { id = 21281 } })
    forge.click("RaidLedgerStart")
    forge.roll("Bob", 20)
    forge.roll("Cara", 70)
    forge.roll("Alice", 10)
    forge.advance(31, 0.25)
    expect(raidSaid("[Loot] " .. TOME .. " won by Alice (10) - main spec, 0 MS / 0 OS items so far.")).toBe(true)
    forge.slash("/ledger clear")
    forge.closeLoot()
end)

test("a correction from another editor's ledger arrives; RESET removes it", function()
    forge.fire("CHAT_MSG_ADDON", "FLLedger", "T;" .. db().session .. ";Alice;0;1;2;0;" .. (time() + 50), "RAID", "Cara")
    expect(db().tallyAdjust.alice.tms).toBe(2)
    local t = tally()
    expect(t).toContain("Alice: 0 main spec, 1 off spec")
    expect(t).toContain("Alice: 2 main spec, 0 off spec (tokens)")
    forge.click("RaidLedgerTabButtonTally")
    forge.click(tallyRow("Bob"))
    forge.click("RaidLedgerTallyReset")
    expect(db().tallyAdjust.bob.ms).toBe(0)
    expect(string.find(tally(), "Bob:", 1, true)).toBeNil()
end)

test("a new raid forgets the corrections", function()
    forge.slash("/ledger newraid confirm")
    expect(next(db().tallyAdjust)).toBeNil()
end)

test("EINSTELLUNGEN: roll lengths, minimap button, window and sync without chat commands", function()
    forge.click("RaidLedgerSettingsButton")
    expect(forge.text("RaidLedgerRollSeconds")).toBe("30")
    forge.type("RaidLedgerRollSeconds", "45")
    forge.type("RaidLedgerTieSeconds", "20")
    forge.click("RaidLedgerApplyTimers")
    expect(db().rollSeconds).toBe(45)
    expect(db().tieSeconds).toBe(20)
    forge.type("RaidLedgerRollSeconds", "5")
    forge.click("RaidLedgerApplyTimers")
    expect(db().rollSeconds).toBe(45)                            -- outside 10-300: refused
    expect(forge.text("RaidLedgerRollSeconds")).toBe("45")
    forge.click("RaidLedgerMinimapToggle")
    expect(db().minimapHidden).toBe(true)
    expect("RaidLedgerMinimapButton").toBeHidden()
    expect(forge.text("RaidLedgerMinimapToggle")).toBe("MINIMAP: OFF")
    forge.click("RaidLedgerMinimapToggle")
    expect("RaidLedgerMinimapButton").toBeShown()
    local before = #forge.addonMessages()
    forge.click("RaidLedgerSync")
    forge.advance(5, 0.25)   -- the request waits behind the queued messages
    local asked = false
    for i = before + 1, #forge.addonMessages() do
        if string.sub(forge.addonMessages()[i].message, 1, 2) == "Q;" then asked = true end
    end
    expect(asked).toBe(true)
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
end)

test("off the editor list the buttons are greyed out", function()
    forge.fire("CHAT_MSG_ADDON", "FLLedger", "E;" .. (time() + 100) .. ";Cara", "RAID", "Cara")
    forge.click("RaidLedgerTabButtonLoot")
    forge.openLoot({ { id = 20513 } })
    expect(forge.frame("RaidLedgerStart"):IsEnabled()).toBeFalsy()
    expect(forge.frame("RaidLedgerAward"):IsEnabled()).toBeFalsy()
    forge.click("RaidLedgerTabButtonTally")
    forge.click(tallyRow("Bob"))
    expect(forge.frame("RaidLedgerTallyPlusms"):IsEnabled()).toBeFalsy()
    forge.closeLoot()
end)
