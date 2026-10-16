-- Easier access for members: a minimap button opens the window, and a roll on
-- a wished item opens it by itself.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
end)

local function receive(message)
    forge.fire("CHAT_MSG_ADDON", "FLLedger", message, "RAID", "Lead")
end

test("the minimap button sits on the minimap and toggles the window", function()
    local button = RaidWishlistMinimapButton
    expect(button:IsShown()).toBe(true)
    local _, anchor = button:GetPoint(1)
    expect(anchor).toBe(Minimap)
    expect("RaidWishlistFrame").toBeHidden()
    forge.click("RaidWishlistMinimapButton")
    expect("RaidWishlistFrame").toBeShown()
    forge.click("RaidWishlistMinimapButton")
    expect("RaidWishlistFrame").toBeHidden()
end)

test("dragging moves the button around the minimap and the place is saved", function()
    Minimap:SetWidth(140)
    Minimap:SetHeight(140)
    Minimap:SetPoint("CENTER", UIParent, "CENTER", 0, 0)      -- centre 640, 360
    forge.stub("GetCursorPosition", function() return 740, 360 end)   -- straight right
    local button = RaidWishlistMinimapButton
    button:GetScript("OnDragStart")(button)
    forge.advance(0.1)
    button:GetScript("OnDragStop")(button)
    expect(math.floor(forge.saved("RaidWishlistDB").minimapAngle + 0.5)).toBe(0)
    local _, _, _, x, y = button:GetPoint(1)
    expect(math.floor(x + 0.5)).toBe(80)
    expect(math.floor(y + 0.5)).toBe(0)
end)

test("/wish minimap off hides the button, also after /reload; on brings it back", function()
    forge.slash("/wish minimap off")
    expect(RaidWishlistMinimapButton:IsShown()).toBe(false)
    expect(forge.chat()).toContain("RaidWishlist: minimap button hidden; /wish minimap on brings it back.")
    forge.reload()
    expect(RaidWishlistMinimapButton:IsShown()).toBe(false)
    forge.slash("/wish minimap on")
    expect(RaidWishlistMinimapButton:IsShown()).toBe(true)
end)

test("a roll on a wished item opens the window; other rolls do not", function()
    forge.slash("/wish import")
    forge.type("RaidWishlistImportText", "WL2;Tester;1792130000;0\n20513;ms;0;1;")
    forge.click("RaidWishlistImportButton")
    forge.slash("/wish")
    expect("RaidWishlistFrame").toBeHidden()
    forge.raid({ "Lead", "Alice" })
    receive("S;Lead-1792131000;Lead;Lead-1-1;50000;30;1;")
    expect("RaidWishlistFrame").toBeHidden()
    receive("S;Lead-1792131000;Lead;Lead-1-2;20513;30;1;")
    expect("RaidWishlistFrame").toBeShown()
    expect("RaidWishlistPrompt").toBeShown()
end)

test("a disenchanted wished item is shown as DE and is not 'received'", function()
    receive(table.concat({ "A", "Lead-1792131000", "Lead", 1, 1, 1792131001, 20513, "", "Tester", "disenchanted",
        1, "", "", "", "", "", 0, "", "21:01" }, ";"))
    forge.slash("/wish")
    if not RaidWishlistFrame:IsShown() then forge.slash("/wish") end
    expect(forge.findText(CREST .. "  ->  Tester")).toBeTruthy()
    expect(forge.findText("DE")).toBeTruthy()
    local items = forge.saved("RaidWishlistDB").chars.Tester.items
    expect(items[1].received).toBeNil()
end)
