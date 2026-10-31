-- The fixed catalogue is searched as literal text, then a selected result uses
-- the same stored entry and sharing path as a manual wishlist item.
local CUFFS = "|cffa335ee|Hitem:39247:0:0:0:0:0:0:0:80|h[Cuffs of Dark Shadows]|h|r"

before_load(function()
    forge.item(39247, { name = "Cuffs of Dark Shadows", link = CUFFS, quality = 4 })
end)

local function db() return forge.saved("RaidWishlistDB") end

test("catalogue finds English raid loot and adds the selected result", function()
    forge.slash("/wish edit")
    forge.type("RaidWishlistCatalogueSearch", "Cuffs of Dark")
    forge.click("RaidWishlistCatalogueGo")
    expect(forge.findText("Cuffs of Dark Shadows")).toBeTruthy()
    expect(forge.findText("Naxxramas")).toBeTruthy()
    expect(forge.layoutIssues("RaidWishlistEditorPanel")).toEqual({})
    forge.sketch("catalogue-search", RaidWishlistEditorPanel)

    forge.click("RaidWishlistCatalogue1")
    expect(forge.layoutIssues("RaidWishlistEditorPanel")).toEqual({})
    forge.sketch("catalogue-selected", RaidWishlistEditorPanel)
    forge.click("RaidWishlistEditorOS")
    forge.type("RaidWishlistEditorNote", "For shadow set")
    forge.click("RaidWishlistEditorSave")
    expect(db().chars.Tester.items[1].itemID).toBe(39247)
    expect(db().chars.Tester.items[1].spec).toBe("os")
    expect(db().chars.Tester.items[1].note).toBe("For shadow set")
    expect(forge.findText("1. " .. CUFFS)).toBeTruthy()
end)

test("catalogue drop-down filters results by raid and quality and shows an item tooltip", function()
    forge.slash("/wish edit")
    expect(forge.findText("ALL RAIDS")).toBeTruthy()
    forge.click("RaidWishlistCatalogueFilter")
    forge.click("RaidWishlistCatalogueR2")
    expect(forge.findText("Naxxramas")).toBeTruthy()
    forge.click("RaidWishlistCatalogueQuality")
    forge.click("RaidWishlistCatalogueQ2")
    expect(forge.findText("Epic")).toBeTruthy()
    forge.type("RaidWishlistCatalogueSearch", "Cuffs of Dark")
    forge.click("RaidWishlistCatalogueGo")
    forge.hover(forge.findText("Cuffs of Dark Shadows"))
    expect(forge.tooltip()[1]).toBe("item:39247")

    forge.click("RaidWishlistCatalogueQuality")
    forge.click("RaidWishlistCatalogueQ3")
    expect(forge.findText("Legendary")).toBeTruthy()
    expect(forge.findText("No raid loot matches that name.")).toBeTruthy()
end)

test("catalogue explains empty, unknown, and unsafe searches without adding an item", function()
    local before = #db().chars.Tester.items
    forge.slash("/wish edit")
    forge.click("RaidWishlistCatalogueGo")
    expect(forge.findText("Enter an item name to search the raid catalogue.")).toBeTruthy()
    forge.type("RaidWishlistCatalogueSearch", "not-in-wotlk-raids")
    forge.click("RaidWishlistCatalogueGo")
    expect(forge.findText("No raid loot matches that name.")).toBeTruthy()
    forge.type("RaidWishlistCatalogueSearch", "|Hitem:39247")
    forge.click("RaidWishlistCatalogueGo")
    expect(forge.findText("Search text cannot contain |.")).toBeTruthy()
    expect(#db().chars.Tester.items).toBe(before)
    expect(forge.layoutIssues("RaidWishlistEditorPanel")).toEqual({})
end)

test("the catalogue holds only epic and legendary loot", function()
    forge.slash("/wish edit")
    forge.click("RaidWishlistCatalogueFilter")
    forge.click("RaidWishlistCatalogueR1")
    forge.click("RaidWishlistCatalogueQuality")
    forge.click("RaidWishlistCatalogueQ1")
    -- Poor, uncommon and rare drops of these raids (quality 0, 2 and 3).
    for _, name in ipairs({ "Abandoned Greatsword", "Adamant Mallet", "Agin's Crushing Carapace" }) do
        forge.type("RaidWishlistCatalogueSearch", name)
        forge.click("RaidWishlistCatalogueGo")
        expect(forge.findText("No raid loot matches that name.")).toBeTruthy()
    end
    forge.click("RaidWishlistCatalogueQuality")
    expect(forge.findText("Rare")).toBe(nil)
    expect(forge.findText("Legendary")).toBeTruthy()
end)
