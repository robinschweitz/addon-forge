-- The settings page (raider screenshot 2026-10-26): each section has one gold
-- heading, texts start at the panel's left edge, and edit boxes line up with
-- their labels. InputBoxTemplate draws its left border 5 px left of the box,
-- which the emulator does not model, so the box itself sits 5 px further in.
before_load(function()
    forge.locale("deDE")
end)

local function left(region) return math.floor(region:GetLeft() + 0.5) end

test("Enhance points have one heading, like the reminder section", function()
    forge.slash("/wish")
    forge.click("RaidWishlistSettingsOpen")
    local heading = forge.findText("ENHANCE-PUNKTE")
    local reminder = forge.findText("CHAT-WÜRFEL-ERINNERUNG")
    expect(heading).toBeTruthy()
    expect(forge.findText("Enhance-Punkte")).toBe(nil)
    expect(heading:GetFontObject()).toBe(reminder:GetFontObject())
    expect({ heading:GetTextColor() }).toEqual({ reminder:GetTextColor() })
end)

test("texts and edit boxes line up at the left edge", function()
    local heading = forge.findText("ENHANCE-PUNKTE")
    local hint = forge.findText("Eine Erinnerung braucht einen Wunsch-Itemlink und ein Schlüsselwort.")
    -- The hint is left-justified (the emulator has no GetJustifyH yet; the
    -- sketch below draws the justification).
    expect(left(hint)).toBe(left(heading))
    expect(left(RaidWishlistEditorPoints) - 5).toBe(left(heading))
    expect(left(RaidWishlistReminderKeywords) - 5).toBe(left(heading))
    expect(forge.layoutIssues("RaidWishlistSettingsPanel")).toEqual({})
    forge.sketch("settings-layout", RaidWishlistSettingsPanel)
end)

test("the editor's edit boxes line up with their labels too", function()
    forge.slash("/wish edit")
    local label = forge.findText("Itemname suchen")
    for _, box in ipairs({ RaidWishlistCatalogueSearch, RaidWishlistEditorItem, RaidWishlistEditorNote }) do
        expect(left(box) - 5).toBe(left(label))
    end
    expect(forge.layoutIssues("RaidWishlistEditorPanel")).toEqual({})
end)
