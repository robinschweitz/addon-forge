-- The client's item cache (g_itemDBCache, GameUI_Scripts Script_GetItemInfo):
-- GetItemInfo answers only for cached items and never asks the server. Showing
-- the item in a tooltip asks (ASSUMPTION: tooltip code is not in the
-- decompilation; verified live with RaidWishlist), and the answer arrives later.
-- 3.3.5a has no event for it (GET_ITEM_INFO_RECEIVED is 4.x).
local LINK = "|cffa335ee|Hitem:20514:0:0:0:0:0:0:0:60|h[Abyssal Boots]|h|r"

before_load(function()
    forge.item(20514, { name = "Abyssal Boots", link = LINK, quality = 4, cached = false })
end)

test("an item the client never saw has no info, asking again does not help", function()
    expect(GetItemInfo(20514)).toBeNil()
    forge.advance(1)
    expect(GetItemInfo(20514)).toBeNil()
    expect(GetItemInfo("item:20514")).toBeNil()
end)

test("a tooltip asks the server; the answer arrives on a later frame", function()
    GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    GameTooltip:SetHyperlink("item:20514")
    expect(GetItemInfo(20514)).toBeNil()
    expect(GameTooltipTextLeft1:GetText()).toBe(RETRIEVING_ITEM_INFO)
    forge.advance(0.1)
    local name, link = GetItemInfo(20514)
    expect(name).toBe("Abyssal Boots")
    expect(link).toBe(LINK)
end)

test("items in a loot window are known", function()
    forge.item(20515, { name = "Abyssal Cloth", link = "item:20515", cached = false })
    forge.openLoot({ { id = 20515 } })
    expect(GetItemInfo(20515)).toBe("Abyssal Cloth")
end)
