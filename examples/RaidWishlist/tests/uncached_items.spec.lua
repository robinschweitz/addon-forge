-- Items the raider's client has never seen (live screenshot 2026-10-24: a
-- wish showed "item:20514"): GetItemInfo knows nothing about them until the
-- server is asked. The wishlist shows a readable placeholder, asks the server
-- with a hidden tooltip, and redraws when the name arrives.
local BOOTS = "|cffa335ee|Hitem:20514:0:0:0:0:0:0:0:60|h[Abyssal Boots]|h|r"
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
    forge.item(20514, { name = "Abyssal Boots", link = BOOTS, quality = 4, cached = false })
end)

local function receive(message)
    forge.fire("CHAT_MSG_ADDON", "FLLedger", message, "RAID", "Lead")
end

test("an unknown item shows a placeholder, then its name once the server answered", function()
    forge.raid({ "Lead", "Tester" })
    forge.slash("/wish")
    forge.click("RaidWishlistImportOpen")
    forge.type("RaidWishlistImportText", "WL2;Tester;1792130000;20\n20513;ms;1;1;BiS\n20514;os;0;2;boots")
    forge.click("RaidWishlistImportButton")
    expect(forge.text("RaidWishlistWish1")).toContain(CREST)
    expect(forge.text("RaidWishlistWish2")).toBe("2. [Item 20514]")
    forge.advance(2, 0.2)
    expect(forge.text("RaidWishlistWish2")).toBe("2. " .. BOOTS)
    expect(forge.layoutIssues("RaidWishlistFrame")).toEqual({})
end)

test("the roll prompt names an item that arrives during the roll", function()
    forge.item(20515, { name = "Abyssal Shroud", link = "|cffa335ee|Hitem:20515:0:0:0:0:0:0:0:60|h[Abyssal Shroud]|h|r",
        quality = 4, cached = false })
    forge.click("RaidWishlistImportOpen")
    forge.type("RaidWishlistImportText", "WL2;Tester;1792130000;20\n20515;ms;0;1;")
    forge.click("RaidWishlistImportButton")
    forge.slash("/wish auto off")
    receive("S;Lead-1792131000;Lead;Lead-1-1;20515;30;1;")
    expect("RaidWishlistPrompt").toBeShown()
    forge.advance(2, 0.2)
    expect(forge.findText("[Abyssal Shroud]", true)).toBeTruthy()
    expect(forge.findText("[Item 20515]", true)).toBeNil()
    expect(#forge.errors()).toBe(0)
end)
