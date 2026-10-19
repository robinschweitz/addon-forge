-- Shared ledger: awards and roll logs go to the other addon users in the group
-- (addon messages, prefix FLLedger), corrections travel back, and a crashed
-- master looter gets the ledger back with /ledger sync.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local TOME = "|cffa335ee|Hitem:21281:0:0:0:0:0:0:0:60|h[Grimoire of Shadow Bolt]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.item(21281, { name = "Grimoire of Shadow Bolt", link = TOME, quality = 4 })
end)

local function db() return forge.saved("RaidLedgerDB") end

-- sentSince returns addon messages sent after the n-th; roll starts (S) and
-- open-item lists (O) only with withStarts, so award tests see just A, L, Q.
local function sentSince(n, withStarts)
    local out = {}
    local all = forge.addonMessages()
    for i = n + 1, #all do
        local kind = string.sub(all[i].message, 1, 2)
        -- Hellos and editor lists (H, HQ, HW, E) are not about awards.
        local hello = kind == "H;" or kind == "HQ" or kind == "HW" or kind == "E;"
        if not hello and (withStarts or (kind ~= "S;" and kind ~= "O;")) then table.insert(out, all[i]) end
    end
    return out
end

local function receive(message, sender, channel)
    forge.fire("CHAT_MSG_ADDON", "FLLedger", message, channel or "RAID", sender or "Alice")
end

local function award(id, rolls)
    forge.slash("/ledger clear")
    forge.openLoot({ { id = id } })
    forge.slash("/ledger start")
    for _, r in ipairs(rolls) do forge.roll(r[1], r[2], r[3], r[4]) end
    forge.advance(31, 0.25)
    forge.clickText("RECORD AWARD")
    forge.closeLoot()
    return db().history[1]
end

local captured = {}

test("after login the addon asks its group for the shared ledger and the wishlists", function()
    forge.raid({ "Alice", "Bob", "Cara" })
    expect(#forge.addonMessages()).toBe(0)
    forge.advance(9, 0.25)
    local sent = sentSince(0)
    expect(#sent).toBe(2)
    expect(sent[1].message).toBe("Q;-;Tester")
    expect(sent[1].chatType).toBe("RAID")
    expect(sent[2].message).toBe("WQ;Tester")
end)

test("an award goes to the group as an A line plus its roll log, four messages a second", function()
    local before = #forge.addonMessages()
    local record = award(20513, { { "Bob", 70 }, { "Alice", 30, 1, 99 }, { "Bob", 99 } })
    forge.advance(0.3, 0.25)
    local sent = sentSince(before)
    expect(#sent).toBe(1)                          -- throttled
    forge.advance(1, 0.25)
    sent = sentSince(before)
    expect(#sent).toBe(2)
    expect(sent[1].prefix).toBe("FLLedger")
    expect(sent[1].chatType).toBe("RAID")
    local session = db().session
    expect(sent[1].message).toBe(string.format("A;%s;Tester;%d;1;%d;20513;;Bob;manual;1;ms;70;1;100;Bob;2;;%s",
        session, record.id, record.at, record.time))
    expect(sent[2].message).toBe(string.format("L;%s;Tester;%d;1;1;Bob,70,1,100,1,,0/Alice,30,1,99,1,,0/Bob,99,1,100,1,r,",
        session, record.id))
    for _, m in ipairs(sent) do table.insert(captured, m.message) end
end)

test("a correction is shared with a higher revision", function()
    local before = #forge.addonMessages()
    forge.slash("/ledger set 1 Cara")
    forge.advance(0.5, 0.25)
    local sent = sentSince(before)
    expect(#sent).toBe(1)
    expect(sent[1].message).toContain(";Tester;1;2;")
    expect(sent[1].message).toContain(";Cara;manual;")
    table.insert(captured, sent[1].message)
end)

test("another raid's ledger is not merged into one with its own awards", function()
    receive("A;Alice-99;Alice;1;1;1281052900;21281;;Bob;given;1;os;12;1;99;Bob;1;;12:01")
    expect(#db().history).toBe(1)
    expect(forge.chat()).toContain("RaidLedger: Alice shares another raid's ledger; yours has its own awards, so it is not merged. Use CLEAR to follow theirs.")
end)

test("an empty ledger follows the master looter's raid and shows its awards", function()
    forge.slash("/ledger newraid confirm")
    receive("A;Alice-99;Alice;5;1;1281052900;21281;15209;Bob;given;1;os;12;1;99;Bob;2;;12:01")
    receive("L;Alice-99;Alice;5;1;1;Bob,12,1,99,1,,0/Dora,80,1,1000,1,x,")
    expect(db().session).toBe("Alice-99")
    local record = db().history[1]
    expect(record.origin).toBe("Alice")
    expect(record.item).toBe(TOME)
    expect(record.recipient).toBe("Bob")
    expect(record.spec).toBe("os")
    expect(record.npc).toBe(15209)
    expect(record.rollLog[1].kind).toBe("os")
    expect(record.rollLog[2].note).toBe("1-1000")
    forge.click("RaidLedgerTabButtonAwards")
    expect(forge.findText("#5  12:01  " .. TOME)).toBeTruthy()
    expect(forge.text(forge.frame("RaidLedgerAwardLine1").columns[2])).toBe("Bob")
    forge.click("RaidLedgerTabButtonLoot")
end)

test("older revisions are ignored, newer ones update", function()
    receive("A;Alice-99;Alice;5;1;1281052900;21281;15209;Eve;given;1;os;12;1;99;Bob;2;;12:01")
    expect(db().history[1].recipient).toBe("Bob")
    receive("A;Alice-99;Alice;5;3;1281052900;21281;15209;Dora;manual;1;os;12;1;99;Bob;2;;12:01")
    expect(db().history[1].recipient).toBe("Dora")
    expect(db().history[1].rev).toBe(3)
end)

test("messages from outside the group, other channels or yourself are ignored", function()
    receive("A;Alice-99;Alice;6;1;1281052950;20513;;Zed;given;1;ms;50;1;100;Zed;1;;12:02", "Stranger")
    receive("A;Alice-99;Alice;6;1;1281052950;20513;;Zed;given;1;ms;50;1;100;Zed;1;;12:02", "Alice", "WHISPER")
    receive("A;Alice-99;Alice;6;1;1281052950;20513;;Zed;given;1;ms;50;1;100;Zed;1;;12:02", "Tester")
    receive("A;Alice-99;Alice;x;1;;;", "Alice")
    expect(#db().history).toBe(1)
    expect(#forge.errors()).toBe(0)
end)

test("an officer's correction of the master looter's award goes back with the same origin", function()
    local before = #forge.addonMessages()
    forge.slash("/ledger set 5 Bob")
    forge.advance(0.5, 0.25)
    local sent = sentSince(before)
    expect(sent[1].message).toContain("A;Alice-99;Alice;5;4;")
    expect(sent[1].message).toContain(";Bob;manual;")
end)

test("a sync request is answered with our own awards and the asker's", function()
    forge.slash("/ledger newraid confirm")
    award(20513, { { "Bob", 40 } })
    receive("A;" .. db().session .. ";Alice;2;1;1281052900;21281;;Cara;given;1;ms;5;1;100;Cara;1;;12:01")
    receive("A;" .. db().session .. ";Bob;3;1;1281052910;21281;;Dora;given;1;ms;5;1;100;Dora;1;;12:02")
    expect(#db().history).toBe(3)
    forge.advance(2, 0.25)
    local before = #forge.addonMessages()
    receive("Q;-;Alice", "Alice")
    forge.advance(2, 0.25)
    local origins = {}
    for _, m in ipairs(sentSince(before)) do
        if string.sub(m.message, 1, 2) == "A;" then table.insert(origins, string.match(m.message, "^A;[^;]*;([^;]*)")) end
    end
    table.sort(origins)
    expect(origins).toEqual({ "Alice", "Tester" })
end)

test("a master looter who lost the ledger gets it back from the group", function()
    forge.slash("/ledger newraid confirm")            -- as if the client crashed
    expect(#db().history).toBe(0)
    forge.slash("/ledger sync")
    forge.advance(0.5, 0.25)
    expect(forge.addonMessages()[#forge.addonMessages()].message).toBe("Q;-;Tester")
    for _, message in ipairs(captured) do receive(message, "Alice") end
    local record = db().history[1]
    expect(record.origin).toBe("Tester")
    expect(record.recipient).toBe("Cara")
    expect(#record.rollLog).toBe(3)
    expect(db().nextID >= record.id).toBe(true)
    local again = award(21281, { { "Bob", 10 } })
    expect(again.id > record.id).toBe(true)
end)

test("a roll start goes to the group first, and a tie-break names the tied players", function()
    forge.slash("/ledger newraid confirm")
    forge.advance(3, 0.25)                         -- drain earlier messages
    forge.slash("/ledger clear")
    forge.openLoot({ { id = 20513 } })
    award(21281, { { "Bob", 10 } })                -- leaves A + L messages queued
    local before = #forge.addonMessages()
    forge.openLoot({ { id = 20513 } })
    forge.slash("/ledger start")
    forge.advance(0.3, 0.25)
    local start = sentSince(before, true)[1].message
    expect(start).toContain(";20513;30;1;")
    expect(string.match(start, "^S;[^;]+;Tester;Tester%-%d+%-%d+;20513;30;1;$")).toBeTruthy()
    forge.roll("Alice", 77)
    forge.roll("Cara", 77)                          -- Bob has an item now: no tie with him
    forge.advance(31, 0.25)
    local tie
    for _, m in ipairs(sentSince(before, true)) do
        if string.sub(m.message, 1, 2) == "S;" and string.find(m.message, ";15;2;", 1, true) then tie = m.message end
    end
    expect(tie).toBeTruthy()
    expect(string.match(tie, ";2;(.*)$")).toBe("Alice,Cara")
    forge.closeLoot()
end)
