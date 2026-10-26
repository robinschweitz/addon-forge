-- A real raid has 25 members with names up to 12 letters, not the two-player
-- test party. The roll list ranks the selected item's rollers (winner first,
-- with what each has so far); ALLE opens every member by raid group.
-- Saves drawings (.forge-runs/sketches) to review how the window looks.
local NAMES = {
    "Test", "Schattenherz", "Morgenröte", "Eisenfaust", "Lichtbringer", "Donnerhuf", "Nachtfalke",
    "Feuerherz", "Sturmwind", "Blutmond", "Grimmbart", "Silberpfeil", "Frostbeule", "Dunkelwald",
    "Kriegsschrei", "Heiligenlied", "Steinhaut", "Waldläuferin", "Zornesglut", "Mondsichel",
    "Knochenmann", "Seelenfänger", "Glutfaust", "Runenwächter", "Elfenstaub",
}
-- Loot with long German names: three wait parked with raiders, one on the corpse.
local LONG_ITEMS = {
    [45510] = "Schulterschutz des unerschütterlichen Wächters",
    [45511] = "Siegelring der verlorenen Hoffnung",
    [45512] = "Gamaschen des Sturmrufers",
    [45513] = "Halskette der gefallenen Sterne",
}
local function linkOf(id) return "|cffa335ee|Hitem:" .. id .. ":0:0:0:0:0:0:0:80|h[" .. LONG_ITEMS[id] .. "]|h|r" end
local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

before_load(function()
    forge.locale("deDE", { RANDOM_ROLL_RESULT = "%1$s würfelt. Ergebnis: %2$d (%3$d-%4$d)" })
    forge.item(45509, { name = "Armschienen des Unsagbaren",
        link = "|cffa335ee|Hitem:45509:0:0:0:0:0:0:0:80|h[Armschienen des Unsagbaren]|h|r", quality = 4 })
    for id, name in pairs(LONG_ITEMS) do
        forge.item(id, { name = name, link = "|cffa335ee|Hitem:" .. id .. ":0:0:0:0:0:0:0:80|h[" .. name .. "]|h|r", quality = 4 })
    end
end)

local function rollLine(i) return forge.frame("RaidLedgerRollLine" .. i) end

-- SPÄTER WÜRFELN asks who keeps the item (FR-RL-012): the name in the box,
-- else the player, picked from the raid list.
local function laterTo(name)
    forge.click("RaidLedgerPark")
    name = (name and name ~= "") and name or UnitName("player")
    for g = 1, 5 do
        for r = 1, 5 do
            local cell = forge.frame("RaidLedgerMember" .. g .. "_" .. r)
            if cell and cell:IsShown() and cell.fullName == name then return forge.click(cell) end
        end
    end
    error("no raid list entry for " .. name)
end

test("before anyone rolls, ALLE counts the whole raid", function()
    local members = {}
    for i, name in ipairs(NAMES) do
        members[i] = { name = name, subgroup = math.ceil(i / 5), classToken = CLASSES[(i - 1) % 10 + 1] }
    end
    forge.raid(members)
    forge.masterLoot(NAMES)
    forge.openLoot({ { id = 45509 } })
    if not RaidLedgerFrame:IsShown() then forge.slash("/ledger") end
    expect(forge.text("RaidLedgerAllMembers")).toBe("ALLE (25)")
    expect(rollLine(1):IsShown()).toBe(false)
end)

test("the rolls are ranked like the roll (winner first); invalid ones last, grey", function()
    forge.slash("/ledger start")
    forge.roll(NAMES[12], 88)
    forge.roll(NAMES[17], 61, 21, 120)                                  -- enhanced main spec
    forge.roll(NAMES[22], 99, 1, 99)                                    -- off spec ranks after main spec
    forge.roll(NAMES[9], 300, 1, 1000)                                  -- invalid: listed with the reason
    forge.advance(5, 0.25)
    expect(forge.text(rollLine(1))).toBe(NAMES[12] .. "  MS")
    expect(forge.text(rollLine(2))).toBe(NAMES[17] .. "  MS 21-120")
    expect(forge.text(rollLine(3))).toBe(NAMES[22] .. "  OS")
    expect(forge.text(rollLine(4))).toContain(NAMES[9] .. "  - ignoriert: 1-1000")
    expect(forge.text(rollLine(1).columns[1])).toBe("88")
    expect(forge.text(rollLine(3).columns[1])).toBe("99")
    forge.click(rollLine(2))
    expect(forge.text(forge.frame("RaidLedgerRecipient"))).toBe(NAMES[17])
    forge.sketch("full-raid-roll", "RaidLedgerFrame")
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
end)

test("ALLE shows every member in five raid-group columns; a click picks the recipient", function()
    forge.click("RaidLedgerAllMembers")
    expect("RaidLedgerMembers").toBeShown()
    for g = 1, 5 do expect(forge.findText("GRUPPE " .. g)).toBeTruthy() end
    for _, name in ipairs(NAMES) do expect(forge.findText(name)).toBeTruthy() end
    -- Column of group 3 holds members 11-15, top to bottom.
    local top = forge.rect(forge.findText(NAMES[11])).top
    expect(forge.rect(forge.findText(NAMES[15])).top < top).toBe(true)
    expect(forge.rect(forge.findText(NAMES[11])).left).toBe(forge.rect(forge.findText(NAMES[15])).left)
    expect(forge.rect(forge.findText(NAMES[11])).left > forge.rect(forge.findText(NAMES[6])).left).toBe(true)
    expect(forge.layoutIssues("RaidLedgerMembers")).toEqual({})
    -- It leaves ALLE (to close it) and the recipient box uncovered, inside the window.
    local pane, window = forge.rect("RaidLedgerMembers"), forge.rect("RaidLedgerFrame")
    expect(pane.bottom >= forge.rect("RaidLedgerAllMembers").top).toBe(true)
    expect(pane.bottom >= window.bottom + 2).toBe(true)
    expect(pane.left >= window.left + 2).toBe(true)
    forge.sketch("full-raid-members", "RaidLedgerFrame")
    forge.clickText(NAMES[24])
    expect(forge.text(forge.frame("RaidLedgerRecipient"))).toBe(NAMES[24])
    expect("RaidLedgerMembers").toBeHidden()
end)

test("ALLE closes the list again", function()
    forge.click("RaidLedgerAllMembers")
    expect("RaidLedgerMembers").toBeShown()
    forge.click("RaidLedgerAllMembers")
    expect("RaidLedgerMembers").toBeHidden()
end)

test("open items parked with raiders stay in the loot list, under the running roll's loot", function()
    forge.openLoot({ { id = 45510 }, { id = 45511 }, { id = 45512 }, { id = 45513 } })
    for _, park in ipairs({ { 45510, NAMES[2] }, { 45511, NAMES[22] }, { 45512, NAMES[1] } }) do
        forge.clickText(linkOf(park[1]))
        forge.type("RaidLedgerRecipient", park[2])
        laterTo(forge.text("RaidLedgerRecipient"))
        forge.advance(0.1)
    end
    expect(forge.findText("BEUTE (2)  |  3 OFFEN")).toBeTruthy()
    -- The corpse's loot first (the running roll, then the last drop), then the open items.
    expect(forge.text("RaidLedgerItemRow3")).toBe("OFFENE ITEMS (3)")
    local open = 0
    for i = 4, 6 do
        local text = forge.text(forge.frame("RaidLedgerItemRow" .. i).columns[1])
        if string.sub(text, 1, 4) == "bei " then open = open + 1 end
    end
    expect(open).toBe(3)
    expect(forge.text("RaidLedgerItemRow4")).toContain("Schulterschutz")
    expect(forge.text(forge.frame("RaidLedgerItemRow4").columns[1])).toBe("bei " .. NAMES[2])
    -- With shared wishlists each row also counts its wishes.
    forge.fire("CHAT_MSG_ADDON", "FLLedger", "W;1792130000;1;1;45510:m:0:1,45512:o:0:2,45509:m:1:1", "RAID", NAMES[7])
    expect(forge.text(forge.frame("RaidLedgerItemRow4").columns[2])).toBe("WL 1")
    -- The running roll selected: its rolls show beside the items.
    forge.clickText("|cffa335ee|Hitem:45509:0:0:0:0:0:0:0:80|h[Armschienen des Unsagbaren]|h|r")
    expect(forge.findText(NAMES[12], true)).toBeTruthy()
    forge.sketch("full-raid-open", "RaidLedgerFrame")
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
    expect(#forge.errors()).toBe(0)
end)
