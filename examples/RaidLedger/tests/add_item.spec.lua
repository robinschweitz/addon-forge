-- FR-RL-033 (raid feedback 2026-11-17): tokens that reached a raider without
-- a master-loot window are added by hand in BEUTE: the item link is
-- shift-clicked into the add box, the holder's name typed, and HINZUFÜGEN
-- adds one open copy per press.
local TOKEN = "|cffa335ee|Hitem:52025:0:0:0:0:0:0:0:80|h[Weiheabzeichen des Bezwingers]|h|r"

before_load(function()
    forge.item(52025, { name = "Weiheabzeichen des Bezwingers", link = TOKEN, quality = 4 })
end)

local function db() return forge.saved("RaidLedgerDB") end

local function openCopies(holder)
    local n = 0
    for _, record in ipairs(db() and db().history or {}) do
        if record.itemID == 52025 and record.state == "parked" and (not holder or record.recipient == holder) then
            n = n + 1
        end
    end
    return n
end

local function rowShowing(text)
    for i = 1, 10 do
        local row = forge.frame("RaidLedgerItemRow" .. i)
        if row and row:IsShown() and string.find(forge.text(row) or "", text, 1, true) then return row end
    end
end

local function setUp()
    local names = { "Tester", "Alice", "Bob", "Cara" }
    forge.raid(names)
    forge.masterLoot(names)
    forge.slash("/ledger newraid confirm")
    forge.slash("/ledger clear")
    if not RaidLedgerFrame:IsShown() then forge.slash("/ledger") end
    forge.click("RaidLedgerTabButtonLoot")
    if RaidLedgerAddItem:IsShown() then forge.click("RaidLedgerAddItemClose") end
end

test("FR-RL-033 a shift-clicked token is added as an open item held by the named raider", function()
    setUp()
    forge.click("RaidLedgerAddItemOpen")
    expect("RaidLedgerAddItem").toBeShown()
    -- A shift-click on an item goes through ChatEdit_InsertLink into the focused box.
    forge.frame("RaidLedgerAddItemLink"):SetFocus()
    ChatEdit_InsertLink(TOKEN)
    expect(forge.frame("RaidLedgerAddItemLink"):GetText()).toBe(TOKEN)
    forge.type("RaidLedgerAddItemHolder", "Bob")
    forge.click("RaidLedgerAddItemAdd")
    expect(openCopies("Bob")).toBe(1)
    expect(rowShowing("Weiheabzeichen")).toBeTruthy()
    -- The dialog stays open: two more presses add two more copies, one 3x row.
    forge.click("RaidLedgerAddItemAdd")
    forge.click("RaidLedgerAddItemAdd")
    expect(openCopies("Bob")).toBe(3)
    expect(rowShowing("3x")).toBeTruthy()
    -- Not in VERGABEN: open items are listed in BEUTE only (FR-RL-004).
    expect(forge.frame("RaidLedgerAddItemLink"):HasFocus()).toBeFalsy()
end)

test("FR-RL-033 the added bundle rolls like any open token bundle", function()
    forge.click(rowShowing("3x"))
    forge.click("RaidLedgerStart")
    local said = false
    for _, m in ipairs(forge.sent()) do
        if string.find(m.message, "3x " .. TOKEN, 1, true) and string.find(m.message, "/rnd", 1, true) then said = true end
    end
    expect(said).toBe(true)
end)

test("FR-RL-033 without a link or with a name outside the raid nothing is added", function()
    setUp()
    forge.click("RaidLedgerAddItemOpen")
    forge.type("RaidLedgerAddItemLink", "")
    forge.type("RaidLedgerAddItemHolder", "Bob")
    forge.click("RaidLedgerAddItemAdd")
    expect(openCopies()).toBe(0)
    expect(forge.findText("Shift-click an item into the item box first.", true)).toBeTruthy()
    forge.type("RaidLedgerAddItemLink", TOKEN)
    forge.type("RaidLedgerAddItemHolder", "Fremder")
    forge.click("RaidLedgerAddItemAdd")
    expect(openCopies()).toBe(0)
    expect(forge.findText("Fremder is not in the raid.", true)).toBeTruthy()
    -- Text that only looks like a link is not an item.
    forge.type("RaidLedgerAddItemLink", "[Weiheabzeichen]")
    forge.type("RaidLedgerAddItemHolder", "Bob")
    forge.click("RaidLedgerAddItemAdd")
    expect(openCopies()).toBe(0)
end)

test("FR-RL-033 an empty name keeps the item with yourself, and the open item is shared", function()
    setUp()
    local before = #forge.addonMessages()
    forge.click("RaidLedgerAddItemOpen")
    forge.type("RaidLedgerAddItemLink", TOKEN)
    forge.type("RaidLedgerAddItemHolder", "")
    forge.click("RaidLedgerAddItemAdd")
    expect(openCopies("Tester")).toBe(1)
    forge.advance(2, 0.25)   -- shared messages go out a few per second
    local shared = false
    for i = before + 1, #forge.addonMessages() do
        local m = forge.addonMessages()[i]
        if m.prefix == "FLLedger" and string.find(m.message, "52025", 1, true) then shared = true end
    end
    expect(shared).toBe(true)
end)

test("FR-RL-033 a raider who is not an editor cannot add items", function()
    setUp()
    -- Cara's editor list leaves you out.
    forge.fire("CHAT_MSG_ADDON", "FLLedger", "E;" .. (time() + 100) .. ";Cara,Alice", "RAID", "Cara")
    forge.click("RaidLedgerAddItemOpen")
    forge.type("RaidLedgerAddItemLink", TOKEN)
    forge.type("RaidLedgerAddItemHolder", "Bob")
    forge.click("RaidLedgerAddItemAdd")
    expect(openCopies()).toBe(0)
    expect(forge.findText("Only the editors", true)).toBeTruthy()
end)
