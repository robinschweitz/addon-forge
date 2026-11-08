-- Raid history (FR-RL-023 to FR-RL-028): NEW RAID keeps the finished raid,
-- the VERLAUF tab lists the saved raids, a saved raid can be shown, corrected,
-- reopened and deleted, and a sync from another raid is stored beside ours.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local TOME = "|cffa335ee|Hitem:21281:0:0:0:0:0:0:0:60|h[Grimoire of Shadow Bolt]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.item(21281, { name = "Grimoire of Shadow Bolt", link = TOME, quality = 4 })
end)

local function db() return forge.saved("RaidLedgerDB") end

local function receive(message, sender)
    forge.fire("CHAT_MSG_ADDON", "FLLedger", message, "RAID", sender or "Alice")
end

local function award(id, rolls)
    if not RaidLedgerFrame:IsShown() then forge.slash("/ledger") end
    forge.click("RaidLedgerTabButtonLoot")
    forge.slash("/ledger clear")
    forge.openLoot({ { id = id } })
    forge.slash("/ledger start")
    for _, r in ipairs(rolls) do forge.roll(r[1], r[2], r[3], r[4]) end
    forge.advance(31, 0.25)
    forge.click("RaidLedgerAward")
    forge.closeLoot()
    return db().history[1]
end

local function sentSince(n, kind)
    local out = {}
    local all = forge.addonMessages()
    for i = n + 1, #all do
        if string.sub(all[i].message, 1, string.len(kind)) == kind then table.insert(out, all[i].message) end
    end
    return out
end

local function lastPopup()
    local popups = forge.popups()
    return popups[#popups]
end

local function open(tab)
    if not RaidLedgerFrame:IsShown() then forge.slash("/ledger") end
    forge.click(tab)
end

local firstSession, firstExport

test("FR-RL-023 NEW RAID keeps the finished raid with all its awards", function()
    forge.raid({ "Alice", "Bob", "Cara" })
    forge.advance(9, 0.25)
    award(20513, { { "Bob", 70 } })
    award(21281, { { "Cara", 50, 1, 99 } })
    forge.slash("/ledger raid 41")
    forge.slash("/ledger tally")   -- (just exercise it)
    firstSession = db().session
    if not RaidLedgerFrame:IsShown() then forge.slash("/ledger") end
    forge.slash("/ledger export")
    firstExport = forge.text("RaidLedgerExportText")
    forge.slash("/ledger newraid confirm")
    expect(#db().history).toBe(0)
    expect(db().raidID).toBe(nil)
    expect(#db().raids).toBe(1)
    local saved = db().raids[1]
    expect(saved.session).toBe(firstSession)
    expect(saved.recorder).toBe("Tester")
    expect(saved.raidID).toBe(41)
    expect(#saved.history).toBe(2)
    expect(saved.history[2].recipient).toBe("Bob")
    expect(#saved.history[2].rollLog).toBe(1)
end)

test("FR-RL-027 a saved raid's awards no longer count in the current raid's rolls", function()
    award(20513, { { "Bob", 30 }, { "Cara", 20 } })
    -- Bob won in the saved raid, but here he starts at 0 items and wins the roll.
    expect(db().history[1].recipient).toBe("Bob")
    expect(db().history[1].rollLog[1].tally or 0).toBe(0)
end)

test("FR-RL-024 the VERLAUF tab lists the saved raids newest first", function()
    forge.slash("/ledger newraid confirm")
    expect(#db().raids).toBe(2)
    expect(db().raids[2].session).toBe(firstSession)
    open("RaidLedgerTabButtonHistory")
    expect(forge.text("RaidLedgerRaidRow1")).toContain("Tester")
    expect(forge.text("RaidLedgerRaidRow2")).toContain("Tester")
    expect(forge.text("RaidLedgerRaidRow2Count")).toContain("2")
    expect(forge.text("RaidLedgerRaidRow1Count")).toBe("1 award")   -- one award, not "1 awards"
    expect(forge.text("RaidLedgerRaidRow2Raid")).toContain("41")
end)

test("FR-RL-024 a selected raid shows its tallies and its export", function()
    forge.click("RaidLedgerRaidRow2")
    -- Bob 1 main spec item, Cara 1 off spec item in that raid only.
    local found = {}
    for i = 1, 4 do
        local text = forge.text("RaidLedgerRaidTally" .. i) or ""
        if string.find(text, "Bob", 1, true) then found.bob = text end
        if string.find(text, "Cara", 1, true) then found.cara = text end
    end
    expect(found.bob ~= nil).toBe(true)
    expect(found.cara ~= nil).toBe(true)

    forge.click("RaidLedgerRaidShow")
    expect(RaidLedgerHistoryPane.heading:GetText()).toContain("2")
    expect(forge.text("RaidLedgerAwardLine1")).toContain("Grimoire")
    forge.click("RaidLedgerExport")
    local text = forge.text("RaidLedgerExportText")
    local function body(export) return string.gsub(export, "^[^\n]*\n", "") end
    local function head(export) return string.match(export, "^(RS2;LOOT;%d+;[^;]+;%d+)") end
    expect(body(text)).toBe(body(firstExport))
    expect(head(text)).toBe(head(firstExport))
    expect(#forge.layoutIssues(RaidLedgerFrame)).toBe(0)
    forge.sketch("history-export", RaidLedgerFrame)
end)

test("FR-RL-027 an editor corrects a saved raid and the group gets it", function()
    forge.click("RaidLedgerTabButtonAwards")   -- back to the awards
    forge.click("RaidLedgerAwardLine2")   -- #1 Abyssal Crest to Bob
    forge.type("RaidLedgerAwardRecipient", "Alice")
    forge.advance(5, 0.25)               -- earlier awards leave the queue first
    local before = #forge.addonMessages()
    forge.click("RaidLedgerChangeRecipient")
    forge.advance(1, 0.25)
    expect(db().raids[2].history[2].recipient).toBe("Alice")
    expect(#db().history).toBe(0)          -- the current raid is untouched
    local sent = sentSince(before, "A;")
    expect(#sent).toBe(1)
    expect(sent[1]).toContain("A;" .. firstSession .. ";Tester;")
    expect(string.sub(sent[1], -2)).toBe(";1")   -- marked: a closed raid
    forge.click("RaidLedgerShowCurrent")
    expect(RaidLedgerHistoryPane.heading:GetText()).toContain("0")
end)

test("FR-RL-027 a correction of a raid we do not hold is ignored", function()
    local raids = #db().raids
    receive("A;Zed-5;Zed;3;2;1281052900;21281;;Bob;given;1;os;12;1;99;Bob;1;;12:01;1", "Alice")
    expect(#db().raids).toBe(raids)
    expect(#db().history).toBe(0)
end)

test("FR-RL-025 a saved raid is reopened after a confirmation", function()
    award(20513, { { "Cara", 60 } })
    local today = db().session
    open("RaidLedgerTabButtonHistory")
    forge.click("RaidLedgerRaidRow2")     -- the first raid (session firstSession)
    forge.click("RaidLedgerRaidReopen")
    expect(lastPopup().which).toBe("RAIDLEDGER_REOPEN_RAID")
    StaticPopupDialogs["RAIDLEDGER_REOPEN_RAID"].OnAccept(nil, lastPopup().data)
    expect(db().session).toBe(firstSession)
    expect(#db().history).toBe(2)
    expect(db().raidID).toBe(41)
    local kept = false
    for _, raid in ipairs(db().raids) do
        if raid.session == today and #raid.history == 1 then kept = true end
        expect(raid.session ~= firstSession).toBe(true)
    end
    expect(kept).toBe(true)
    local highest = 0
    for _, raid in ipairs(db().raids) do
        for _, r in ipairs(raid.history) do highest = math.max(highest, r.id) end
    end
    for _, r in ipairs(db().history) do highest = math.max(highest, r.id) end
    local record = award(21281, { { "Bob", 10 } })
    expect(#db().history).toBe(3)
    expect(record.id).toBe(highest + 1)
end)

test("FR-RL-028 deleting a saved raid asks, removes it only here and sends nothing", function()
    local raids = #db().raids
    open("RaidLedgerTabButtonHistory")
    forge.click("RaidLedgerRaidRow2")
    forge.click("RaidLedgerRaidDelete")
    expect(lastPopup().which).toBe("RAIDLEDGER_DELETE_RAID")
    expect(lastPopup().text1 ~= nil).toBe(true)
    StaticPopupDialogs["RAIDLEDGER_DELETE_RAID"].OnCancel(nil, lastPopup().data)
    expect(#db().raids).toBe(raids)
    forge.advance(5, 0.25)               -- earlier awards leave the queue first
    local before = #forge.addonMessages()
    forge.click("RaidLedgerRaidDelete")
    local victim = lastPopup().data
    StaticPopupDialogs["RAIDLEDGER_DELETE_RAID"].OnAccept(nil, victim)
    expect(#db().raids).toBe(raids - 1)
    forge.advance(1, 0.25)
    expect(#forge.addonMessages()).toBe(before)
    expect(#db().history).toBe(3)        -- the current raid stays
end)

test("FR-RL-026 a sync from another raid is stored beside ours and offered", function()
    local raids = #db().raids
    local popups = #forge.popups()
    local MONDAY = "A;Alice-77;Alice;7;1;1281052900;21281;;Bob;given;1;os;12;1;99;Bob;1;;12:01"
    receive(MONDAY)
    expect(#db().raids).toBe(raids + 1)
    local stored
    for _, raid in ipairs(db().raids) do if raid.session == "Alice-77" then stored = raid end end
    expect(stored.recorder).toBe("Alice")
    expect(#stored.history).toBe(1)
    expect(stored.history[1].recipient).toBe("Bob")
    expect(#db().history).toBe(3)                       -- ours is unchanged
    expect(#forge.popups()).toBe(popups + 1)            -- told, and asked
    expect(lastPopup().which).toBe("RAIDLEDGER_FOLLOW_RAID")
    receive(MONDAY)
    receive("A;Alice-77;Alice;7;2;1281052900;21281;;Cara;given;1;os;12;1;99;Bob;1;;12:01")
    expect(#db().raids).toBe(raids + 1)                 -- updated, not stored twice
    expect(stored.history[1].recipient).toBe("Cara")
    -- One other raid per sender: a second made-up raid from Alice is not stored.
    receive("A;Alice-88;Alice;1;1;1281052900;21281;;Bob;given;1;os;12;1;99;Bob;1;;12:01")
    expect(#db().raids).toBe(raids + 1)
    expect(#forge.popups()).toBe(popups + 1)

    StaticPopupDialogs["RAIDLEDGER_FOLLOW_RAID"].OnAccept(nil, lastPopup().data)
    expect(db().session).toBe("Alice-77")
    expect(#db().history).toBe(1)
    local ours = false
    for _, raid in ipairs(db().raids) do if raid.session == firstSession then ours = #raid.history == 3 end end
    expect(ours).toBe(true)
end)

test("FR-RL-023 the player chooses how many raids to keep", function()
    open("RaidLedgerTabButtonHistory")
    forge.type("RaidLedgerKeepRaids", "2")
    forge.press("RaidLedgerKeepRaids", "ENTER")
    expect(db().keepRaids).toBe(2)
    for _ = 1, 3 do
        award(20513, { { "Bob", 5 } })
        forge.slash("/ledger newraid confirm")
    end
    expect(#db().raids).toBe(2)
    forge.type("RaidLedgerKeepRaids", "500")
    forge.press("RaidLedgerKeepRaids", "ENTER")
    expect(db().keepRaids).toBe(500)
    forge.type("RaidLedgerKeepRaids", "0")
    forge.press("RaidLedgerKeepRaids", "ENTER")
    expect(db().keepRaids).toBe(500)                    -- at least one raid
end)
