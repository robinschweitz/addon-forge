-- Raider feedback 2026-10-18: the ledger gets a minimap button like RaidWishlist's.

test("the minimap button sits on the minimap and toggles the ledger", function()
    local button = RaidLedgerMinimapButton
    expect(button:IsShown()).toBe(true)
    local _, anchor = button:GetPoint(1)
    expect(anchor).toBe(Minimap)
    expect("RaidLedgerFrame").toBeShown()
    forge.click("RaidLedgerMinimapButton")
    expect("RaidLedgerFrame").toBeHidden()
    forge.click("RaidLedgerMinimapButton")
    expect("RaidLedgerFrame").toBeShown()
end)

test("dragging moves the button around the minimap and the place is saved", function()
    Minimap:SetWidth(140)
    Minimap:SetHeight(140)
    Minimap:SetPoint("CENTER", UIParent, "CENTER", 0, 0)      -- centre 640, 360
    forge.stub("GetCursorPosition", function() return 640, 460 end)   -- straight up
    local button = RaidLedgerMinimapButton
    button:GetScript("OnDragStart")(button)
    forge.advance(0.1)
    button:GetScript("OnDragStop")(button)
    expect(math.floor(forge.saved("RaidLedgerDB").minimapAngle + 0.5)).toBe(90)
    local _, _, _, x, y = button:GetPoint(1)
    expect(math.floor(x + 0.5)).toBe(0)
    expect(math.floor(y + 0.5)).toBe(80)
end)

test("/ledger minimap off hides the button, also after /reload; on brings it back", function()
    forge.slash("/ledger minimap off")
    expect(RaidLedgerMinimapButton:IsShown()).toBe(false)
    expect(forge.chat()).toContain("RaidLedger: minimap button hidden; /ledger minimap on brings it back.")
    forge.reload()
    expect(RaidLedgerMinimapButton:IsShown()).toBe(false)
    forge.slash("/ledger minimap on")
    expect(RaidLedgerMinimapButton:IsShown()).toBe(true)
    forge.slash("/ledger help")
    expect(forge.chat()).toContain("RaidLedger: /ledger minimap on|off - show or hide the minimap button")
end)

test("the tooltip names the addon and what a click does", function()
    forge.hover("RaidLedgerMinimapButton")
    local tip = forge.tooltip()
    expect(tip).toContain("RaidLedger")
    expect(tip).toContain("Click: open or close the ledger")
end)
