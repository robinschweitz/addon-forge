-- Raid feedback of 2026-10-19 (first real raid with two ledgers in the group):
-- only the award's own recorder announces it, a shared award of an item the
-- client has not cached yet never shows as "item:50667", the "so far" count
-- includes items already won but not handed out yet and names both specs, and
-- a roll without takers says "nobody wanted it".
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local TOME = "|cffa335ee|Hitem:21281:0:0:0:0:0:0:0:60|h[Grimoire of Shadow Bolt]|h|r"
local BELT = "|cffa335ee|Hitem:50667:0:0:0:0:0:0:0:80|h[Waistband of Righteous Fury]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.item(21281, { name = "Grimoire of Shadow Bolt", link = TOME, quality = 4 })
end)

local function db() return forge.saved("RaidLedgerDB") end

local function receive(message, sender)
    forge.fire("CHAT_MSG_ADDON", "FLLedger", message, "RAID", sender or "Alice")
end

local function sentSince(n)
    local out = {}
    for i = n + 1, #forge.sent() do table.insert(out, forge.sent()[i].message) end
    return out
end

-- said: everything the addon wrote, to local chat or sent to raid chat.
local function said()
    local out = {}
    for _, line in ipairs(forge.chat()) do table.insert(out, line) end
    for _, m in ipairs(forge.sent()) do table.insert(out, m.message) end
    return out
end

-- pick selects the loot row that shows `link`.
local function pick(link)
    for i = 1, 10 do
        local row = forge.frame("RaidLedgerRow" .. i)
        if row and row:IsShown() and forge.text(row) == link then return forge.click(row) end
    end
    error("no loot row shows " .. link)
end

local function roll(id, rolls)
    forge.slash("/ledger clear")
    forge.openLoot({ { id = id } })
    forge.slash("/ledger start")
    for _, r in ipairs(rolls) do forge.roll(r[1], r[2], r[3], r[4]) end
    forge.advance(31, 0.25)
end

test("another ledger's award is not announced again when its loot line arrives", function()
    forge.raid({ "Alice", "Bob", "Cara" })
    forge.slash("/ledger newraid confirm")
    receive("A;Alice-99;Alice;5;1;1281052900;21281;15209;Bob;given;0;os;12;1;99;Bob;2;;12:01")
    local before = #forge.sent()
    forge.fire("CHAT_MSG_LOOT", "Bob receives loot: " .. TOME .. ".")
    expect(#sentSince(before)).toBe(0)
    -- Alice's ledger confirms it and shares that; this copy stays as received.
    expect(db().history[1].confirmed).toBe(false)
    receive("A;Alice-99;Alice;5;2;1281052900;21281;15209;Bob;given;1;os;12;1;99;Bob;2;;12:01")
    expect(db().history[1].confirmed).toBe(true)
    expect(#sentSince(before)).toBe(0)
end)

test("a shared award of an item this client has not seen gets its link once the item is known", function()
    receive("A;Alice-99;Alice;6;1;1281052950;50667;36597;Cara;given;1;ms;80;1;100;Cara;3;;12:05")
    local record = db().history[1]
    expect(record.itemID).toBe(50667)
    forge.item(50667, { name = "Waistband of Righteous Fury", link = BELT, quality = 4 })
    forge.slash("/ledger")   -- show: the history refreshes
    if not RaidLedgerFrame:IsShown() then forge.slash("/ledger") end
    expect(record.item).toBe(BELT)
    expect(forge.findText("|  " .. BELT .. "  ->  Cara", true)).toBeTruthy()
end)

test("an item won but not handed out yet counts in the next roll's 'so far'", function()
    forge.slash("/ledger newraid confirm")
    forge.slash("/ledger clear")
    forge.openLoot({ { id = 20513 }, { id = 21281 } })
    -- Both items stay in the loot window while they are rolled one after the other.
    pick(CREST)
    forge.slash("/ledger start")
    forge.roll("Bob", 70)
    forge.advance(31, 0.25)
    expect(said()).toContain("[Loot] " .. CREST .. " won by Bob (70) - main spec, 0 MS / 0 OS items so far.")
    pick(TOME)
    forge.slash("/ledger start")
    forge.roll("Bob", 60)
    forge.roll("Cara", 40, 1, 99)
    forge.advance(31, 0.25)
    -- Bob's crest is not handed out yet but is his; Cara rolled off spec, so
    -- Bob still wins on main spec, with one item so far.
    expect(said()).toContain("[Loot] " .. TOME .. " won by Bob (60) - main spec, 1 MS / 0 OS items so far.")
    forge.closeLoot()
end)

test("a pending win ranks the next roll: the player without items wins", function()
    forge.slash("/ledger newraid confirm")
    forge.slash("/ledger clear")
    forge.openLoot({ { id = 20513 }, { id = 21281 } })
    pick(CREST)
    forge.slash("/ledger start")
    forge.roll("Bob", 70)
    forge.advance(31, 0.25)
    pick(TOME)
    forge.slash("/ledger start")
    forge.roll("Bob", 90)
    forge.roll("Cara", 20)
    forge.advance(31, 0.25)
    expect(said()).toContain("[Loot] " .. TOME .. " won by Cara (20) - main spec, 0 MS / 0 OS items so far.")
    forge.closeLoot()
end)

test("the 'so far' count of an off-spec win shows the main-spec items too", function()
    forge.slash("/ledger newraid confirm")
    roll(20513, { { "Bob", 70 } })
    forge.clickText("RECORD AWARD")
    forge.closeLoot()
    roll(21281, { { "Bob", 50, 1, 99 } })
    expect(said()).toContain("[Loot] " .. TOME .. " won by Bob (50) - off spec, 1 MS / 0 OS items so far.")
    forge.closeLoot()
end)

test("a roll nobody takes says so in chat and in the loot list", function()
    forge.slash("/ledger newraid confirm")
    roll(20513, {})
    expect(said()).toContain("[Loot] " .. CREST .. " - nobody wanted it.")
    expect(forge.findText("NOBODY")).toBeTruthy()
    forge.closeLoot()
end)
