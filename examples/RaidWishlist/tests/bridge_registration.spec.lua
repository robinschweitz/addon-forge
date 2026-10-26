-- The live bridge accepts only names up to 32 characters. Keep every observed
-- editor control inside that contract so a registration error cannot hide it.
local registered = {}

before_load(function()
    ForgeTestBridge = {
        RegisterFrame = function(_, name, frame)
            if #name > 32 or type(frame.IsShown) ~= "function" then error("invalid bridge frame", 2) end
            registered[name] = true
        end,
    }
end)

test("all registered wishlist controls satisfy the bridge contract", function()
    expect(#forge.errors()).toBe(0)
    expect(registered.RaidWishlistCatalogueGo).toBe(true)
    expect(registered.RaidWishlistCatalogueFilter).toBe(true)
    expect(registered.RaidWishlistCatalogueQuality).toBe(true)
    expect(registered.RaidWishlistCatalogue1).toBe(true)
    expect(registered.RaidWishlistEditorOS).toBe(true)
    expect(registered.RaidWishlistSettingsOpen).toBe(true)
    expect(registered.RaidWishlistSettingsFromEditor).toBe(true)
    expect(registered.RaidWishlistEditorPoints).toBe(true)
    expect(registered.RaidWishlistEditorPointsSave).toBe(true)
    expect(registered.RaidWishlistEditorSave).toBe(true)
    expect(registered.RaidWishlistReminderCancel).toBe(true)
end)
