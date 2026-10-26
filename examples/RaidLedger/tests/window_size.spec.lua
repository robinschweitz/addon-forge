-- The window can be resized with the grip in its lower right corner and scaled
-- (SETTINGS or /ledger scale), for small and large screens. Lists show more
-- rows in a taller window, panes use the full width, and size and scale stay
-- after /reload. Saves drawings of the large window with a full raid.
local NAMES = {
    "Test", "Schattenherz", "Morgenröte", "Eisenfaust", "Lichtbringer", "Donnerhuf", "Nachtfalke",
    "Feuerherz", "Sturmwind", "Blutmond", "Grimmbart", "Silberpfeil", "Frostbeule", "Dunkelwald",
    "Kriegsschrei", "Heiligenlied", "Steinhaut", "Waldläuferin", "Zornesglut", "Mondsichel",
    "Knochenmann", "Seelenfänger", "Glutfaust", "Runenwächter", "Elfenstaub",
}
local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

before_load(function()
    forge.locale("deDE", { RANDOM_ROLL_RESULT = "%1$s würfelt. Ergebnis: %2$d (%3$d-%4$d)" })
    for i = 1, 40 do
        local id = 45000 + i
        local name = "Schulterschutz des unerschütterlichen Wächters " .. i
        forge.item(id, { name = name, link = "|cffa335ee|Hitem:" .. id .. ":0:0:0:0:0:0:0:80|h[" .. name .. "]|h|r", quality = 4 })
    end
end)

local TABS = { awards = "RaidLedgerTabButtonAwards", tally = "RaidLedgerTabButtonTally",
    raid = "RaidLedgerRaidButton", settings = "RaidLedgerSettingsButton" }
-- The client keeps the scale as a 32-bit float (0.8 reads back as 0.80000001192093).
local function scale() return math.floor(RaidLedgerFrame:GetScale() * 100 + 0.5) / 100 end
local function shown(name) local f = forge.frame(name); return f ~= nil and f:IsVisible() end
local function size() return RaidLedgerFrame:GetWidth(), RaidLedgerFrame:GetHeight() end

-- The corpse popup alone offers SPÄTER WÜRFELN (FR-RL-012).
local function laterTo(name)
    forge.click("RaidLedgerMasterLootLater")
    name = (name and name ~= "") and name or UnitName("player")
    for g = 1, 5 do
        for r = 1, 5 do
            local cell = forge.frame("RaidLedgerMasterLootMember" .. g .. "_" .. r)
            if cell and cell:IsShown() and cell.fullName == name then return forge.click(cell) end
        end
    end
    error("no raid list entry for " .. name)
end

local function fullRaid()
    local members = {}
    for i, name in ipairs(NAMES) do
        members[i] = { name = name, subgroup = math.ceil(i / 5), classToken = CLASSES[(i - 1) % 10 + 1] }
    end
    forge.raid(members)
    forge.masterLoot(NAMES)
    -- 20 items parked with raiders, then a corpse with 10 drops: 31 loot lines.
    for i = 1, 20 do
        forge.openLoot({ { id = 45020 + i } })
        forge.type(forge.frame("RaidLedgerRecipient"), NAMES[i + 1])
        laterTo(forge.text("RaidLedgerRecipient"))
        forge.advance(0.1)
        forge.closeLoot()
    end
    local loot = {}
    for i = 1, 10 do loot[i] = { id = 45000 + i } end
    forge.openLoot(loot)
    if not RaidLedgerFrame:IsShown() then forge.slash("/ledger") end
end

test("the window starts at 760x480 and scale 100%, and fits the screen", function()
    fullRaid()
    local w, h = size()
    expect(w).toBe(760)
    expect(h).toBe(480)
    expect(scale()).toBe(1)
    expect(shown("RaidLedgerItemRow16")).toBe(true)
    expect(forge.frame("RaidLedgerItemRow17")).toBeNil()
end)

test("the grip in the lower right corner resizes the window", function()
    expect("RaidLedgerResize").toBeShown()
    local grip, window = forge.rect("RaidLedgerResize"), forge.rect("RaidLedgerFrame")
    expect(window.right - grip.right <= 6).toBe(true)
    expect(grip.bottom - window.bottom <= 6).toBe(true)
    local top, left = window.top, window.left
    forge.drag("RaidLedgerResize", 240, -140)
    local w, h = size()
    expect(w).toBe(1000)
    expect(h).toBe(620)
    expect(forge.rect("RaidLedgerFrame").top).toBe(top)
    expect(forge.rect("RaidLedgerFrame").left).toBe(left)
end)

test("a taller window shows more list rows, wider panes reach the right edge", function()
    -- 140 px taller: seven more item rows (18 px each), seven more roll rows.
    expect(shown("RaidLedgerItemRow23")).toBe(true)
    expect(forge.text("RaidLedgerItemRow23")).toContain("Wächters")
    expect(forge.frame("RaidLedgerItemRow24")).toBeNil()
    local window, detail = forge.rect("RaidLedgerFrame"), forge.rect("RaidLedgerDetailPane")
    expect(window.right - detail.right).toBe(16)
    expect(forge.rect("RaidLedgerRollPane").bottom).toBe(detail.bottom)
    expect(detail.bottom - window.bottom).toBe(32)
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
    forge.slash("/ledger start")
    for i = 2, 25 do forge.roll(NAMES[i], 100 - i) end
    forge.advance(1, 0.25)
    expect(shown("RaidLedgerRollLine15")).toBe(true)
    -- The hand-out controls stay at the bottom of the pane.
    expect(forge.rect("RaidLedgerDisenchant").bottom - detail.bottom <= 18).toBe(true)
    expect(forge.rect("RaidLedgerRollLine15").bottom > forge.rect("RaidLedgerRecipient").top).toBe(true)
    forge.sketch("large-loot", "RaidLedgerFrame")
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
end)

test("every tab fits the large window with full data", function()
    forge.click("RaidLedgerAward")
    for _, tab in ipairs({ "awards", "tally", "raid", "settings" }) do
        forge.click(TABS[tab])
        expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
        forge.sketch("large-" .. tab, "RaidLedgerFrame")
    end
    forge.click("RaidLedgerTabButtonLoot")
end)

test("the window cannot shrink below 760x480 or grow past the screen's edges", function()
    forge.drag("RaidLedgerResize", -2000, 2000)
    local w, h = size()
    expect(w).toBe(760)
    expect(h).toBe(480)
    forge.drag("RaidLedgerResize", 4000, -4000)
    local r = forge.rect("RaidLedgerFrame")
    expect(r.right <= 1280 and r.bottom >= 0).toBe(true)
end)

test("/ledger scale sets the scale; out of range is refused", function()
    forge.slash("/ledger reset")
    forge.slash("/ledger scale 80")
    expect(scale()).toBe(0.8)
    expect(forge.saved("RaidLedgerDB").window.scale).toBe(0.8)   -- not the client's float32 read-back
    expect(math.floor(forge.rect("RaidLedgerFrame").width + 0.5)).toBe(608)
    forge.slash("/ledger scale 300")
    expect(scale()).toBe(0.8)
    expect(forge.lastChat()).toContain("/ledger scale")
end)

test("SETTINGS changes the scale in steps of 10% and shows it", function()
    forge.click(TABS.settings)
    expect(forge.text("RaidLedgerScaleValue")).toBe("80%")
    forge.click("RaidLedgerScaleUp")
    expect(scale()).toBe(0.9)
    expect(forge.text("RaidLedgerScaleValue")).toBe("90%")
    forge.click("RaidLedgerScaleDown")
    forge.click("RaidLedgerScaleDown")
    expect(forge.text("RaidLedgerScaleValue")).toBe("70%")
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
end)

test("a large scale keeps the window on the screen", function()
    forge.drag("RaidLedgerResize", 4000, -4000)
    forge.slash("/ledger scale 150")
    local r = forge.rect("RaidLedgerFrame")
    expect(r.width <= 1280 and r.height <= 720).toBe(true)
    local w, h = size()
    expect(w).toBe(853)       -- 1280 / 1.5 wide at most, 720 / 1.5 = 480 high
    expect(h).toBe(480)
end)

test("size and scale stay after /reload", function()
    forge.slash("/ledger scale 90")
    forge.drag("RaidLedgerResize", 90, -45)
    local w, h = size()
    w, h = math.floor(w + 0.5), math.floor(h + 0.5)   -- saved in whole pixels
    forge.reload()
    forge.advance(0.1)
    expect(scale()).toBe(0.9)
    local w2, h2 = size()
    expect(w2).toBe(w)
    expect(h2).toBe(h)
    expect(shown("RaidLedgerItemRow18")).toBe(true)
end)

test("/ledger reset brings back the default size, scale and place", function()
    forge.slash("/ledger reset")
    local w, h = size()
    expect(w).toBe(760)
    expect(h).toBe(480)
    expect(scale()).toBe(1)
    expect(forge.frame("RaidLedgerItemRow17"):IsShown()).toBe(false)
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
    expect(#forge.errors()).toBe(0)
end)
