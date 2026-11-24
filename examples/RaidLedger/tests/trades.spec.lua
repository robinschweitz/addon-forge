-- FR-RL-032 (raid feedback 2026-11-17): "vielleicht noch nen Log wer was an
-- wen gehandelt hat, auch geteilt". Each RaidLedger writes down the trades of
-- raid loot it makes (who gave which item to whom, and when) and shares them
-- with everyone in the raid who runs RaidLedger. The log changes no award.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local POTION = "|cffffffff|Hitem:33447:0:0:0:0:0:0:0:80|h[Runic Healing Potion]|h|r"
local bags = {}

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.item(33447, { name = "Runic Healing Potion", link = POTION, quality = 1 })
    bags = { [0] = { CREST, POTION } }
    forge.stub("ContainerFrameItemButton_OnModifiedClick", function() end)
    forge.stub("GetContainerItemLink", function(bag, slot) return bags[bag] and bags[bag][slot] end)
    forge.stub("GetContainerNumSlots", function(bag) return bags[bag] and 16 or 0 end)
end)

local function db() return forge.saved("RaidLedgerDB") end
local function trades() return db().trades or {} end

local function receive(message, sender)
    forge.fire("CHAT_MSG_ADDON", "FLLedger", message, "RAID", sender)
end

local function sentKind(kind, since)
    local found = {}
    for i = (since or 0) + 1, #forge.addonMessages() do
        local m = forge.addonMessages()[i]
        if m.prefix == "FLLedger" and string.sub(m.message, 1, string.len(kind) + 1) == kind .. ";" then
            table.insert(found, m.message)
        end
    end
    return found
end

test("FR-RL-032 a trade of raid loot is logged and shared, and no award changes", function()
    local names = { "Tester", "Alice", "Bob", "Cara" }
    forge.raid(names)
    forge.masterLoot(names)
    forge.slash("/ledger newraid confirm")
    forge.slash("/ledger roll 20513")         -- the crest from the bags, Alice wins it
    forge.roll("Alice", 80)
    forge.advance(31, 0.25)
    local record = db().history[1]
    expect(record.recipient).toBe("Alice")
    local before = #forge.addonMessages()
    forge.trade("Alice", { CREST }, { clearOnComplete = true })
    expect(#trades()).toBe(1)
    expect(trades()[1].giver).toBe("Tester")
    expect(trades()[1].receiver).toBe("Alice")
    expect(trades()[1].itemID).toBe(20513)
    -- The award is as it was: the trade log never changes awards (FR-RL-003).
    expect(record.recipient).toBe("Alice")
    expect(record.state).toBe("manual")
    forge.advance(2, 0.25)
    local sent = sentKind("X", before)
    expect(#sent).toBe(1)
    expect(sent[1]).toBe(string.format("X;%s;Alice;20513;%d", db().session, trades()[1].at))
    -- The HANDEL tab lists it.
    forge.click("RaidLedgerTabButtonTrades")
    expect(forge.text("RaidLedgerTradeRow1")).toContain("Tester -> Alice")
    expect(forge.text("RaidLedgerTradeRow1")).toContain("Abyssal Crest")
end)

test("FR-RL-032 potions, cancelled trades and trades outside the raid are not logged", function()
    local before = #forge.addonMessages()
    forge.trade("Alice", { POTION }, { clearOnComplete = true })
    forge.trade("Bob", { CREST }, { cancel = true })
    forge.trade("Fremder", { CREST }, { clearOnComplete = true })
    expect(#trades()).toBe(1)
    forge.advance(2, 0.25)
    expect(#sentKind("X", before)).toBe(0)
end)

test("FR-RL-032 a mate's shared trade is listed under its sender", function()
    local session = db().session
    receive("X;" .. session .. ";Bob;20513;1760000000", "Cara")
    expect(#trades()).toBe(2)
    local entry = trades()[1].giver == "Cara" and trades()[1] or trades()[2]
    expect(entry.giver).toBe("Cara")
    expect(entry.receiver).toBe("Bob")
    -- The same message again adds nothing.
    receive("X;" .. session .. ";Bob;20513;1760000000", "Cara")
    expect(#trades()).toBe(2)
    forge.click("RaidLedgerTabButtonTrades")
    expect(forge.findText("Cara -> Bob", true)).toBeTruthy()
end)

test("FR-RL-032 malformed or foreign trade messages are dropped", function()
    local session = db().session
    receive("X;" .. session .. ";Bob;abc;1760000000", "Cara")             -- no item ID
    receive("X;" .. session .. ";B|cffff0000ob;20513;1760000000", "Cara") -- escape codes in the name
    receive("X;" .. session .. ";;20513;1760000000", "Cara")              -- no receiver
    receive("X;" .. session .. ";Bob;20513", "Cara")                      -- no time
    receive("X;other-session;Bob;20513;1760000001", "Cara")               -- another raid
    receive("X;" .. session .. ";Bob;20513;1760000002", "Fremder")        -- not in the group
    expect(#trades()).toBe(2)
end)

test("FR-RL-032 a new raid starts an empty trade log and keeps the old one with its raid", function()
    forge.slash("/ledger newraid confirm")
    expect(#trades()).toBe(0)
    expect(table.getn(db().raids[1].trades or {})).toBe(2)
    expect(forge.errors()).toEqual({})
end)
