-- Editors and addon users (raid feedback 2026-10-19): a list of names that may
-- change the ledger (start rolls, award, correct), set in the SETTINGS panel or
-- with /ledger allow|deny and shared with the group; everybody else only
-- watches. The panel also shows which raid members run RaidLedger or
-- RaidWishlist. An empty list keeps the old rules.
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

-- sentSince: addon messages after the n-th, without roll starts and open lists.
local function sentSince(n)
    local out = {}
    local all = forge.addonMessages()
    for i = n + 1, #all do
        local kind = string.sub(all[i].message, 1, 2)
        if kind ~= "S;" and kind ~= "O;" then table.insert(out, all[i].message) end
    end
    return out
end

local function raidSaid(text)
    for _, m in ipairs(forge.sent()) do
        if string.find(m.message, text, 1, true) then return true end
    end
    return false
end

local function settings()
    return forge.frame("RaidLedgerSettings")
end

test("after login the ledger says hello and asks who runs the addons", function()
    forge.raid({ { name = "Tester", rank = 2 }, { name = "Alice", rank = 1 }, "Bob", "Cara", "Dora" })
    forge.advance(10, 0.25)
    local sent = table.concat(sentSince(0), "\n")
    expect(sent).toContain("HQ;Tester")
    expect(sent).toContain("H;2.6.0;1")
end)

test("a hello query is answered with this ledger's version", function()
    local before = #forge.addonMessages()
    receive("HQ;Alice")
    forge.advance(2, 0.25)
    expect(table.concat(sentSince(before), "\n")).toContain("H;2.6.0;1")
end)

test("the settings list raid members with their addons", function()
    receive("H;2.5.0;1", "Alice")
    receive("HW;1.5.0", "Bob")
    receive("H;2.3.0;0", "Cara")
    if not RaidLedgerFrame:IsShown() then forge.slash("/ledger") end
    forge.click(forge.frame("RaidLedgerSettingsButton"))
    expect(settings():IsShown()).toBe(true)
    expect(forge.findText("Alice  2.5.0")).toBeTruthy()
    expect(forge.findText("Bob  WL 1.5.0")).toBeTruthy()
    expect(forge.findText("Cara  2.3.0")).toBeTruthy()
    expect(forge.findText("Dora  -")).toBeTruthy()
    expect(forge.findText("ADDON IN THE GROUP (4/5)")).toBeTruthy()
    expect(forge.layoutIssues(RaidLedgerFrame)).toEqual({})
end)

test("adding the first editor in the settings also adds yourself, and the list is shared", function()
    local before = #forge.addonMessages()
    forge.type(forge.frame("RaidLedgerEditorName"), "Alice")
    forge.clickText("ADD")
    expect(db().editors).toEqual({ "Alice", "Tester" })
    forge.advance(1, 0.25)
    local sent = table.concat(sentSince(before), "\n")
    expect(sent).toContain(";Alice,Tester")
    expect(string.sub(sent, 1, 2)).toBe("E;")
    expect(forge.findText("Alice")).toBeTruthy()
    expect(forge.layoutIssues(RaidLedgerFrame)).toEqual({})
end)

test("/ledger deny removes an editor, /ledger allow adds one", function()
    forge.slash("/ledger deny Alice")
    expect(db().editors).toEqual({ "Tester" })
    forge.slash("/ledger allow cara")
    expect(db().editors).toEqual({ "Tester", "Cara" })
    forge.slash("/ledger editors")
    expect(forge.lastChat()).toContain("Tester, Cara")
end)

test("awards from players who are not on the list are ignored", function()
    forge.slash("/ledger newraid confirm")
    receive("A;Bob-99;Bob;1;1;1281052900;21281;;Bob;given;1;ms;50;1;100;Bob;1;;12:01", "Bob")
    expect(#db().history).toBe(0)
    receive("A;Cara-99;Cara;1;1;1281052900;21281;;Dora;given;1;ms;50;1;100;Dora;1;;12:01", "Cara")
    expect(#db().history).toBe(1)
end)

test("a newer list from an editor replaces this one; one from anybody else does not", function()
    receive("E;" .. (time() + 100) .. ";Bob", "Bob")
    expect(db().editors).toEqual({ "Tester", "Cara" })
    receive("E;" .. (time() + 100) .. ";Cara,Alice", "Cara")
    expect(db().editors).toEqual({ "Cara", "Alice" })
end)

test("off the list the ledger only watches: no rolls, no awards, no corrections", function()
    forge.click("RaidLedgerTabButtonLoot")   -- from the settings to the loot
    forge.slash("/ledger newraid confirm")
    local before = #forge.sent()
    forge.openLoot({ { id = 20513 } })
    forge.slash("/ledger start")
    expect(#forge.sent()).toBe(before)
    expect(forge.findText("Only the editors", true)).toBeTruthy()
    forge.type(forge.frame("RaidLedgerRecipient"), "Bob")
    forge.clickText("RECORD AWARD")
    expect(#db().history).toBe(0)
    forge.slash("/ledger set 1 Bob")
    expect(#forge.sent()).toBe(before)
    forge.closeLoot()
end)

test("a list without you cannot be changed by you", function()
    forge.slash("/ledger allow Bob")
    expect(db().editors).toEqual({ "Cara", "Alice" })
    expect(forge.lastChat()).toContain("Only the editors")
end)

test("the editors' own list can be emptied by an editor: the old rules apply again", function()
    receive("E;" .. (time() + 200) .. ";", "Cara")
    expect(db().editors).toEqual({})
    forge.slash("/ledger newraid confirm")
    forge.openLoot({ { id = 20513 } })
    forge.slash("/ledger start")
    expect(raidSaid("[Loot] " .. CREST .. " - /rnd now!")).toBe(true)
    forge.slash("/ledger clear")
    forge.closeLoot()
end)

-- Group loot (need/greed) by accident in the raid of 2026-10-19: the items won
-- were missing from the ledger. One addon user records them, without a spec.
test("an item won with group loot is recorded without a spec and counts for nobody", function()
    -- Alice (an assistant with the addon) left: this ledger is the one to record.
    forge.raid({ { name = "Tester", rank = 2 }, "Bob", "Cara", "Dora" })
    forge.slash("/ledger newraid confirm")
    forge.fire("CHAT_MSG_LOOT", "Bob won: " .. TOME)
    local record = db().history[1]
    expect(record.recipient).toBe("Bob")
    expect(record.state).toBe("given")
    expect(record.spec).toBeNil()
    expect(record.confirmed).toBe(true)
    forge.slash("/ledger tally")
    expect(forge.lastChat()).toContain("no items counted this raid yet.")
end)

test("your own group-loot win is yours, not held for a trade", function()
    forge.fire("CHAT_MSG_LOOT", "You won: " .. CREST)
    expect(db().history[1].recipient).toBe("Tester")
    expect(db().history[1].state).toBe("given")
end)

test("with several ledgers only the first eligible one records group loot", function()
    forge.raid({ { name = "Tester", rank = 2 }, { name = "Alice", rank = 1 }, "Bob", "Cara", "Dora" })
    forge.raid({ { name = "Tester", rank = 2 }, { name = "Alice", rank = 1 }, "Bob", "Cara", "Dora" })
    forge.slash("/ledger newraid confirm")
    receive("H;2.5.0;1", "Alice")      -- Alice is an assistant and sorts first
    forge.fire("CHAT_MSG_LOOT", "Bob won: " .. TOME)
    expect(#db().history).toBe(0)
end)
