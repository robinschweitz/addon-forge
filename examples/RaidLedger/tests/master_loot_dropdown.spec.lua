-- FR-RL-014: GroupLootDropDown is FrameXML, not covered by the headless
-- emulation. Stub its menu builder, but keep the addon's real hook and callbacks.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local TOME = "|cffa335ee|Hitem:21281:0:0:0:0:0:0:0:60|h[Grimoire]|h|r"
local BOOTS = "|cffa335ee|Hitem:20514:0:0:0:0:0:0:0:60|h[Abyssal Boots]|h|r"
local RING = "|cffa335ee|Hitem:20515:0:0:0:0:0:0:0:60|h[Abyssal Ring]|h|r"
local menus = { [1] = {}, [2] = {} }

before_load(function()
    forge.locale("deDE", { RANDOM_ROLL_RESULT = "%1$s würfelt. Ergebnis: %2$d (%3$d-%4$d)" })
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.item(21281, { name = "Grimoire", link = TOME, quality = 4 })
    forge.item(20514, { name = "Abyssal Boots", link = BOOTS, quality = 4 })
    forge.item(20515, { name = "Abyssal Ring", link = RING, quality = 4 })
    forge.stub("LootFrame", CreateFrame("Frame", "LootFrame"))
    LootFrame.selectedSlot = nil
    forge.stub("GroupLootDropDown", {})
    forge.stub("DropDownList1", { numButtons = 0 })
    forge.stub("DropDownList2", { numButtons = 0 })
    forge.stub("UIDropDownMenu_CreateInfo", function() return {} end)
    forge.stub("UIDropDownMenu_AddButton", function(info, level)
        local copy = {}
        for key, value in pairs(info) do copy[key] = value end
        table.insert(menus[level or 1], copy)
    end)
    forge.stub("GroupLootDropDown_Initialize", function(_, level)
        if level == 1 then table.insert(menus[1], { text = "Blizzard" }) end
    end)
end)

local function menu(slot, level, list)
    LootFrame.selectedSlot = slot
    menus[level] = {}
    GroupLootDropDown_Initialize(GroupLootDropDown, level, list)
    return menus[level]
end

local function item(entries, text)
    for _, info in ipairs(entries) do
        if info.text == text then return info end
    end
    error("missing dropdown item: " .. text)
end

test("FR-RL-014 the master-loot dropdown adds ledger actions and records each hand-out", function()
    local names = { "Tester", "Alice", "Bob" }
    forge.raid(names)
    forge.masterLoot(names)
    forge.unit("target", { name = "Templer", guid = "0xF130003B69000114", dead = true, isPlayer = false })
    forge.openLoot({ { id = 20513 }, { id = 21281 }, { id = 20514 }, { id = 20515 } })

    local root = menu(1, 1)
    expect(item(root, "WÜRFELN STARTEN").func).toBeTruthy()
    expect(item(root, "SPÄTER WÜRFELN BEI ...").hasArrow).toBe(true)
    expect(item(root, "ENTZAUBERN (Tester)").func).toBeTruthy()
    expect(item(root, "GILDENBANK").func).toBeTruthy()
    item(root, "WÜRFELN STARTEN").func()
    forge.advance(0.1)
    local started = false
    for _, message in ipairs(forge.sent()) do
        if string.find(message.message, "jetzt /rnd!", 1, true) then started = true end
    end
    expect(started).toBe(true)

    root = menu(2, 1)
    local later = item(root, "SPÄTER WÜRFELN BEI ...")
    expect(later.menuList).toBe("RAIDLEDGER_LATER")
    local submenu = menu(2, 2, later.menuList)
    item(submenu, "Alice").func()
    forge.advance(0.1)
    expect(forge.saved("RaidLedgerDB").history[1].state).toBe("parked")
    expect(forge.saved("RaidLedgerDB").history[1].recipient).toBe("Alice")

    forge.slash("/ledger de Alice")
    root = menu(3, 1)
    item(root, "ENTZAUBERN (Alice)").func()
    forge.advance(0.1)
    expect(forge.saved("RaidLedgerDB").history[1].state).toBe("disenchanted")
    expect(forge.saved("RaidLedgerDB").history[1].recipient).toBe("Alice")

    root = menu(4, 1)
    item(root, "GILDENBANK").func()
    forge.advance(0.1)
    expect(forge.saved("RaidLedgerDB").history[1].state).toBe("bank")
end)
