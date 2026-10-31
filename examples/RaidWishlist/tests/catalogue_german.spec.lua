-- A German search compares the catalogue's deDE names, not client item cache
-- names or English text.
before_load(function()
    forge.locale("deDE")
end)

test("catalogue finds localized German raid loot", function()
    forge.slash("/wish edit")
    forge.type("RaidWishlistCatalogueSearch", "Manschetten der dunklen")
    forge.click("RaidWishlistCatalogueGo")
    expect(forge.findText("Manschetten der dunklen Schatten")).toBeTruthy()
    expect(forge.findText("Naxxramas")).toBeTruthy()
    expect(forge.layoutIssues("RaidWishlistEditorPanel")).toEqual({})
    forge.sketch("catalogue-search-de", RaidWishlistEditorPanel)
end)
