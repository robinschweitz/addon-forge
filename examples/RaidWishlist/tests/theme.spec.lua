-- Raider feedback 2026-10-18: the wishlist window should look like RaidLedger's
-- (no two-line header), keep its own color but let players pick it, and the
-- import field should take typing wherever it is clicked.
local picker

before_load(function()
    -- Blizzard's ColorPickerFrame is not emulated offline; this stand-in
    -- behaves like it: SetColorRGB and the wheel change the color, OK keeps
    -- it, Cancel calls cancelFunc with previousValues.
    picker = { color = { 1, 1, 1 } }
    function picker:SetColorRGB(r, g, b) self.color = { r, g, b } end
    function picker:GetColorRGB() return self.color[1], self.color[2], self.color[3] end
    function picker:SetFrameStrata(strata) self.strata = strata end
    function picker:Show() self.shown = true end
    function picker:Hide() self.shown = false end
    function picker:choose(r, g, b) self:SetColorRGB(r, g, b); if self.func then self.func() end end
    function picker:cancel() self.shown = false; self.cancelFunc(self.previousValues) end
    forge.stub("ColorPickerFrame", picker)
end)

local function openWindow()
    if not RaidWishlistFrame:IsShown() then forge.slash("/wish") end
end

local function close(actual, expected)
    expect(math.abs(actual - expected) < 0.01).toBe(true)
end

test("the header is the addon's name, like RaidLedger, with no subtitle", function()
    openWindow()
    expect(forge.findText("RaidWishlist")).toBeTruthy()
    expect(forge.findText("LOOT WISHLIST")).toBeFalsy()
    expect(forge.findText("WISHLIST FOR", true)).toBeFalsy()
    -- Live run c5507048723a: "Interface\ChatFrame..." with single backslashes
    -- (Lua drops unknown escapes) left the swatch and accent line blank.
    local swatch
    for _, region in ipairs({ RaidWishlistColor:GetRegions() }) do
        if region.GetTexture and region:GetTexture() then swatch = region end
    end
    expect(swatch:GetTexture()).toBe("Interface\\ChatFrame\\ChatFrameBackground")
    expect(forge.layoutIssues("RaidWishlistFrame")).toEqual({})
end)

test("the color button opens the picker; a pick recolors the window and is saved", function()
    openWindow()
    forge.click("RaidWishlistColor")
    expect(picker.shown).toBe(true)
    picker:choose(0.5, 0.2, 1.0)              -- purple: brightest channel becomes 1
    local db = forge.saved("RaidWishlistDB")
    close(db.color[1], 0.5)
    close(db.color[3], 1.0)
    local r, g, b = RaidWishlistFrame:GetBackdropColor()
    expect(b > r and r > g).toBe(true)        -- the window background follows the hue
    forge.reload()
    openWindow()
    close(forge.saved("RaidWishlistDB").color[1], 0.5)
    local r2, g2, b2 = RaidWishlistFrame:GetBackdropColor()
    expect(b2 > r2 and r2 > g2).toBe(true)    -- still purple after /reload
end)

test("cancel in the picker puts the old color back", function()
    openWindow()
    local r0, g0, b0 = RaidWishlistFrame:GetBackdropColor()
    local before = forge.saved("RaidWishlistDB").color   -- the earlier test's purple
    forge.click("RaidWishlistColor")
    picker:choose(1.0, 0.1, 0.1)
    local r1 = RaidWishlistFrame:GetBackdropColor()
    expect(r1 > r0).toBe(true)
    picker:cancel()
    local r2, g2, b2 = RaidWishlistFrame:GetBackdropColor()
    close(r2, r0); close(g2, g0); close(b2, b0)
    expect(forge.saved("RaidWishlistDB").color).toEqual(before)
end)

test("a very dark pick is brightened so text stays readable", function()
    openWindow()
    forge.click("RaidWishlistColor")
    picker:choose(0.02, 0.0, 0.0)
    local _, _, _, a = RaidWishlistFrame:GetBackdropColor()
    local tr, tg, tb = forge.findText("RaidWishlist"):GetTextColor()
    expect(tr).toBeGreaterThan(0.9)            -- title is light red, not black
    expect(tg).toBeGreaterThan(0.35)
    expect(a).toBeGreaterThan(0.9)
end)

test("right-click on the color button and /wish color reset go back to green", function()
    openWindow()
    forge.click("RaidWishlistColor")
    picker:choose(1.0, 0.1, 0.1)
    forge.click("RaidWishlistColor", "RightButton")
    expect(forge.saved("RaidWishlistDB").color).toBeNil()
    local r, g, b = RaidWishlistFrame:GetBackdropColor()
    expect(g > r and g > b).toBe(true)
    forge.slash("/wish color")
    picker:choose(0.2, 0.4, 1.0)
    forge.slash("/wish color reset")
    expect(forge.saved("RaidWishlistDB").color).toBeNil()
    expect(forge.chat()).toContain("RaidWishlist: window color reset.")
end)

test("the full layout stays clean with a picked color and German texts", function()
    openWindow()
    forge.click("RaidWishlistColor")
    picker:choose(1.0, 0.75, 0.2)
    expect(forge.layoutIssues("RaidWishlistFrame")).toEqual({})
    forge.slash("/wish import")
    expect(forge.layoutIssues("RaidWishlistFrame")).toEqual({})
end)

test("a click anywhere in the import field focuses it for typing", function()
    forge.slash("/wish import")
    local field = RaidWishlistImportText
    expect(field:HasFocus()).toBeFalsy()
    local back = field:GetParent():GetParent()     -- the field's frame around the scroll area
    expect(back:IsMouseEnabled()).toBe(true)
    back:GetScript("OnMouseDown")(back, "LeftButton")
    expect(field:HasFocus()).toBeTruthy()
    field:ClearFocus()
    local scroll = field:GetParent()
    scroll:GetScript("OnMouseDown")(scroll, "LeftButton")
    expect(field:HasFocus()).toBeTruthy()
end)
