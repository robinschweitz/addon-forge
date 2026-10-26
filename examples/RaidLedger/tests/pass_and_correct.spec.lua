-- Rules chosen by the user on 2026-10-17: players sometimes realise only after
-- rolling that they do not need the item, and the master looter sometimes
-- decides a roll counts differently. Only the master looter changes rolls
-- (right-click a roll in the roll list under the items, or /ledger pass|count). A pass strikes the roll; once
-- a winner was announced, the next-best roll wins and is announced. A recount
-- as plain main spec subtracts the points (110 from 21-120 counts 90), and the
-- points of an enhanced roll can be corrected (20 EP claimed, 10 EP real:
-- 110 from 21-120 becomes 100 from 11-110).
local BRACERS = "|cffa335ee|Hitem:45509:0:0:0:0:0:0:0:80|h[Bracers of the Untold]|h|r"
local CLOAK = "|cffa335ee|Hitem:45510:0:0:0:0:0:0:0:80|h[Cloak of Whispers]|h|r"

before_load(function()
    forge.item(45509, { name = "Bracers of the Untold", link = BRACERS, quality = 4 })
    forge.item(45510, { name = "Cloak of Whispers", link = CLOAK, quality = 4, tooltip = { "ITEM_BIND_ON_EQUIP" } })
end)

-- Only messages since the test's fresh() count: names and items repeat.
local mark = 0
local function raidSaid(needle)
    local count = 0
    local sent = forge.sent()
    for i = mark + 1, #sent do
        local m = sent[i]
        if m.chatType == "RAID" and string.find(m.message, needle, 1, true) then count = count + 1 end
    end
    return count
end

local function said(text) return raidSaid("[Loot] " .. BRACERS .. " - " .. text) end
local function won(text) return raidSaid("[Loot] " .. BRACERS .. " won by " .. text) end

local function fresh()
    mark = #forge.sent()
    forge.click("RaidLedgerTabButtonLoot")
    forge.closeLoot()
    forge.slash("/ledger clear")
    forge.openLoot({ { id = 45509 } })
    forge.slash("/ledger start")
end

-- The top roll of the selected item (the ranking's leader) and its value.
local function topRoll() return forge.text("RaidLedgerRollLine1") end
local function topValue() return forge.text(forge.frame("RaidLedgerRollLine1").columns[1]) end

-- The roll line for `name`: the selected item's rolls, or the shown award's log.
local function rollRow(name)
    for _, prefix in ipairs({ "RaidLedgerRollLine", "RaidLedgerRoll" }) do
        for i = 1, 10 do
            local row = forge.frame(prefix .. i)
            if row and row:IsVisible() and row.playerName == name then return row end
        end
    end
end

test("a pass during the roll takes the roller out of the ranking", function()
    forge.raid({ "Alice", "Bob", "Cara", "Dora", "Emil" })
    forge.masterLoot({ "Alice", "Bob", "Cara", "Dora", "Emil" })
    fresh()
    forge.roll("Alice", 80)
    forge.roll("Bob", 60)
    expect(topRoll()).toBe("Alice  MS")
    forge.slash("/ledger pass alice")              -- names in any case
    expect(said("Alice passes.")).toBe(1)
    expect(topRoll()).toBe("Bob  MS")
    expect(topValue()).toBe("60")
    forge.advance(31, 0.25)
    expect(won("Bob (60)")).toBe(1)
    expect(won("Alice")).toBe(0)
end)

test("a pass after the winner was announced gives the item to the next-best roll", function()
    fresh()
    forge.roll("Alice", 80)
    forge.roll("Bob", 60)
    forge.roll("Cara", 95, 1, 99)                  -- off spec ranks last
    forge.advance(31, 0.25)
    expect(won("Alice (80)")).toBe(1)
    forge.slash("/ledger pass Alice")
    expect(said("Alice passes.")).toBe(1)
    expect(won("Bob (60)")).toBe(1)
    expect(forge.text(forge.frame("RaidLedgerRecipient"))).toBe("Bob")
    forge.slash("/ledger pass Bob")
    expect(won("Cara (95)")).toBe(1)
    forge.slash("/ledger pass Cara")
    expect(said("nobody wanted it.")).toBe(1)
end)

test("after a tie-break, the other tied player and then the earlier rolls are next", function()
    fresh()
    forge.roll("Alice", 90)
    forge.roll("Bob", 90)
    forge.roll("Cara", 50)
    forge.advance(31, 0.25)
    forge.roll("Alice", 30)
    forge.roll("Bob", 70)
    forge.advance(16, 0.25)
    expect(won("Bob (70)")).toBe(1)
    forge.slash("/ledger pass Bob")
    expect(won("Alice (30)")).toBe(1)
    forge.slash("/ledger pass Alice")
    expect(won("Cara (50)")).toBe(1)
end)

test("a pass during a tie-break ends it: the other tied player wins", function()
    fresh()
    forge.roll("Alice", 90)
    forge.roll("Bob", 90)
    forge.roll("Cara", 50)
    forge.advance(31, 0.25)                        -- tie-break running
    forge.slash("/ledger pass Alice")
    expect(won("Bob (90)")).toBe(1)
end)

test("an enhanced roll recounted as plain main spec loses its points", function()
    fresh()
    forge.roll("Alice", 110, 21, 120)
    forge.roll("Bob", 95)
    forge.advance(31, 0.25)
    expect(won("Alice (110)")).toBe(1)
    forge.slash("/ledger count Alice ms")
    expect(said("Alice's roll counts as main spec (90).")).toBe(1)
    expect(won("Bob (95)")).toBe(1)
end)

test("the points of an enhanced roll can be corrected", function()
    fresh()
    forge.roll("Alice", 110, 21, 120)              -- claimed 20 EP
    forge.roll("Bob", 95)
    forge.slash("/ledger count Alice enh 10")      -- had 10 EP: 100 from 11-110
    expect(said("Alice's roll counts as main spec 11-110 (100).")).toBe(1)
    expect(topValue()).toBe("100")
    forge.slash("/ledger count Bob enh 5")         -- a plain roll can gain points too
    expect(said("Bob's roll counts as main spec 6-105 (100).")).toBe(1)
    forge.slash("/ledger count Bob enh 0")         -- 0 points: plain main spec
    expect(said("Bob's roll counts as main spec (95).")).toBe(1)
    forge.advance(31, 0.25)
    expect(won("Alice (100) - main spec 11-110")).toBe(1)
    forge.click("RaidLedgerAward")
    local record = forge.saved("RaidLedgerDB").history[1]
    expect(record.roll).toBe(100)
    expect(record.low).toBe(11)
    expect(record.high).toBe(110)
    -- The roll log keeps what was rolled, for disputes.
    local alice
    for _, r in ipairs(record.rollLog) do if r.name == "Alice" then alice = r end end
    expect(alice.low).toBe(11)
    expect(alice.was).toBe("110 (21-120)")
    forge.slash("/ledger raid 7")
    forge.slash("/ledger export")
    expect(forge.text("RaidLedgerExportText")).toContain(";100;ms;11-110;Alice")
    forge.clickText("BACK")
    forge.click("RaidLedgerTabButtonLoot")
end)

test("a main-spec roll can count as off spec, or not at all", function()
    fresh()
    forge.roll("Alice", 80)
    forge.roll("Bob", 60)
    forge.roll("Cara", 40)
    forge.slash("/ledger count Alice os")
    expect(said("Alice's roll counts as off spec (80).")).toBe(1)
    forge.slash("/ledger count Bob none")
    expect(said("Bob's roll does not count.")).toBe(1)
    forge.advance(31, 0.25)
    expect(won("Cara (40)")).toBe(1)
end)

test("bad corrections are refused", function()
    fresh()
    forge.roll("Alice", 80)
    forge.slash("/ledger pass Zed")
    expect(forge.chat()).toContain("RaidLedger: Zed has no counted roll on the selected item.")
    forge.slash("/ledger count Alice enh 51")
    expect(forge.chat()).toContain("RaidLedger: usage: /ledger count <name> ms|os|none|enh <0-50>")
    forge.slash("/ledger pass")
    expect(forge.chat()).toContain("RaidLedger: usage: /ledger pass <name>")
end)

test("the selected item's rolls are listed beside the items, with what each roller has so far", function()
    -- Alice got an item above, so her tally would rank her last: roll with others.
    fresh()
    forge.roll("Dora", 80)
    forge.roll("Emil", 60)
    forge.roll("Cara", 300, 1, 1000)               -- ignored, listed grey with the reason
    forge.roll("Bob", 45, 1, 99)
    expect(forge.findText("ROLLS (4)")).toBeTruthy()
    expect(forge.text("RaidLedgerRollLine1")).toBe("Dora  MS")
    expect(forge.text("RaidLedgerRollLine2")).toBe("Emil  MS")
    expect(forge.text("RaidLedgerRollLine3")).toBe("Bob  OS")
    expect(forge.text("RaidLedgerRollLine4")).toContain("Cara  - ignored: 1-1000")
    expect(topValue()).toBe("80")
    expect(forge.text(forge.frame("RaidLedgerRollLine1").columns[2])).toBe("0")   -- Dora's items so far
    forge.click(rollRow("Emil"))                   -- left-click: recipient
    expect(forge.text(forge.frame("RaidLedgerRecipient"))).toBe("Emil")
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
end)

test("right-click on a roll opens the roll menu; PASS strikes the roll", function()
    forge.click(rollRow("Cara"), "RightButton")    -- an ignored roll has nothing to change
    expect("RaidLedgerRollMenu").toBeHidden()
    forge.click(rollRow("Dora"), "RightButton")
    expect("RaidLedgerRollMenu").toBeShown()
    expect(RaidLedgerRollMenu.title:GetText()).toBe("Dora (80)")
    expect(forge.findText("Dora (80)")).toBeTruthy()
    expect(forge.layoutIssues("RaidLedgerRollMenu")).toEqual({})
    -- Under the roll, inside the window.
    local menu, window = forge.rect("RaidLedgerRollMenu"), forge.rect("RaidLedgerFrame")
    expect(menu.top <= forge.rect(rollRow("Dora")).bottom).toBe(true)
    expect(menu.top < window.top - 40 and menu.bottom > window.bottom).toBe(true)
    forge.sketch("roll-menu", "RaidLedgerFrame")
    forge.click("RaidLedgerRollMenuPass")
    expect("RaidLedgerRollMenu").toBeHidden()
    expect(said("Dora passes.")).toBe(1)
    expect(topRoll()).toBe("Emil  MS")
    expect(forge.text(rollRow("Dora"))).toContain("Dora  - ignored: passed")
end)

test("the menu recounts, and ENHANCED asks for the points", function()
    mark = #forge.sent()
    forge.click(rollRow("Emil"), "RightButton")    -- Emil (60)
    forge.click("RaidLedgerRollMenuOS")
    expect(said("Emil's roll counts as off spec (60).")).toBe(1)
    forge.click(rollRow("Emil"), "RightButton")
    forge.click("RaidLedgerRollMenuEnhanced")
    local popups = forge.popups()
    local popup = popups[#popups]
    expect(popup.which).toBe("RAIDLEDGER_POINTS")
    expect(popup.text1).toBe("Emil")
    forge.stub("FakePopupEditBox", { GetText = function() return "12" end })
    StaticPopupDialogs["RAIDLEDGER_POINTS"].OnAccept({ GetName = function() return "FakePopup" end }, popup.data)
    expect(said("Emil's roll counts as main spec 13-112 (72).")).toBe(1)
    forge.click(rollRow("Emil"), "RightButton")
    forge.click("RaidLedgerRollMenuMS")
    expect(said("Emil's roll counts as main spec (60).")).toBe(1)
    forge.click(rollRow("Emil"), "RightButton")
    forge.click("RaidLedgerRollMenuNone")
    expect(said("Emil's roll does not count.")).toBe(1)
end)

test("a free BoE roll can take passes but no spec changes", function()
    forge.closeLoot()
    forge.slash("/ledger clear")
    forge.openLoot({ { id = 45510 } })
    mark = #forge.sent()
    forge.slash("/ledger free")
    forge.roll("Alice", 80)
    forge.roll("Bob", 60)
    forge.slash("/ledger count Alice os")
    expect(forge.chat()).toContain("RaidLedger: a free BoE roll only takes /rnd 100; pass or none only.")
    forge.click(rollRow("Alice"), "RightButton")
    expect("RaidLedgerRollMenuOS").toBeHidden()
    expect("RaidLedgerRollMenuPass").toBeShown()
    forge.click("RaidLedgerRollMenuPass")
    forge.advance(31, 0.25)
    expect(raidSaid("[Loot] " .. CLOAK .. " - free BoE roll won by Bob (60).")).toBe(1)
    expect(#forge.errors()).toBe(0)
end)

test("a long roll list scrolls; the items stay in place", function()
    local names = {}
    for i = 1, 12 do names[i] = "Raider" .. string.char(64 + i) end
    forge.raid(names)
    fresh()
    for i = 1, 12 do forge.roll(names[i], 100 - i) end
    expect(forge.findText("ROLLS (12, SCROLL)")).toBeTruthy()
    expect(forge.text("RaidLedgerRollLine1")).toBe("RaiderA  MS")
    forge.wheel("RaidLedgerDetailPane", -1)
    expect(forge.text("RaidLedgerItemRow1")).toContain("Bracers of the Untold")
    expect(forge.text("RaidLedgerRollLine1")).toBe("RaiderB  MS")
    forge.wheel("RaidLedgerDetailPane", -10)
    expect(forge.text("RaidLedgerRollLine7")).toBe("RaiderL  MS")
    -- The lowest roll's menu still fits inside the window.
    forge.click(rollRow("RaiderL"), "RightButton")
    local menu, window = forge.rect("RaidLedgerRollMenu"), forge.rect("RaidLedgerFrame")
    expect(menu.bottom > window.bottom and menu.top < window.top).toBe(true)
    forge.sketch("roll-menu-low", "RaidLedgerFrame")
    forge.sketch("roll-list", "RaidLedgerFrame")
end)

-- Rule of 2026-10-17: in a given-out award's roll log, a pass or recount that
-- makes someone else the winner re-awards the item (like changing the
-- recipient by hand); with nobody valid left the award stays.
local function awardLine(name)
    forge.click("RaidLedgerTabButtonAwards")
    for i = 1, 18 do
        local line = forge.frame("RaidLedgerAwardLine" .. i)
        if line and line:IsVisible() and forge.text(line.columns[2]) == name then return line end
    end
end

test("a pass in a given-out award's roll log gives the award to the next-best roll", function()
    local names = {}
    for i = 1, 12 do names[i] = "Raider" .. string.char(64 + i) end
    forge.masterLoot(names)
    fresh()
    forge.roll("RaiderA", 90)
    forge.roll("RaiderB", 70)
    forge.roll("RaiderC", 95, 1, 99)
    forge.advance(31, 0.25)
    forge.click("RaidLedgerAward")
    local record = forge.saved("RaidLedgerDB").history[1]
    expect(record.recipient).toBe("RaiderA")
    forge.click(awardLine("RaiderA"))              -- show the award's roll log
    expect(forge.findText("ROLLS (3)")).toBeTruthy()
    forge.click(rollRow("RaiderA"), "RightButton")
    expect("RaidLedgerRollMenu").toBeShown()
    forge.sketch("award-roll-menu", "RaidLedgerFrame")
    forge.click("RaidLedgerRollMenuPass")
    expect(said("RaiderA passes.")).toBe(1)
    expect(raidSaid("[Loot] " .. BRACERS .. " goes to RaiderB - main spec (corrected).")).toBe(1)
    expect(record.recipient).toBe("RaiderB")
    expect(forge.text(forge.frame("RaidLedgerAwardRecipient"))).toBe("RaiderB")   -- the shown award's recipient
    expect(record.winner).toBe("RaiderB")
    expect(record.roll).toBe(70)
    expect(record.spec).toBe("ms")
    -- The award's log shows the pass; the tally moved with the award.
    expect(forge.text(rollRow("RaiderA"))).toContain("RaiderA  - ignored: passed")
    forge.slash("/ledger tally")
    expect(forge.chat()).toContain("RaiderB")
end)

test("slash commands work on the shown award too; a recount can move it again", function()
    forge.slash("/ledger count RaiderB os")        -- now RaiderC's 95 OS beats RaiderB's 70 OS
    expect(said("RaiderB's roll counts as off spec (70).")).toBe(1)
    local record = forge.saved("RaidLedgerDB").history[1]
    expect(record.recipient).toBe("RaiderC")
    expect(record.spec).toBe("os")
    expect(record.roll).toBe(95)
end)

test("with nobody valid left the award stays and asks the master looter", function()
    forge.slash("/ledger pass RaiderB")
    forge.slash("/ledger pass RaiderC")
    local record = forge.saved("RaidLedgerDB").history[1]
    expect(record.recipient).toBe("RaiderC")
    expect(forge.findText("Award #" .. record.id .. ": no valid roll is left; decide who gets it (DE, BANK or another recipient).")).toBeTruthy()
    forge.slash("/ledger pass RaiderZ")
    expect(forge.chat()).toContain("RaidLedger: RaiderZ has no counted roll on award #" .. record.id .. ".")
end)
