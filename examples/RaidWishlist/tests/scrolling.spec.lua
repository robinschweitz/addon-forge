-- Long lists (raid feedback 2026-10-20: "you cannot scroll down the loot"):
-- every tab's list scrolls with the mouse wheel to its last entry, says where
-- it is, and stays free of layout issues with a busy raid.
before_load(function()
    for id = 40001, 40045 do
        forge.item(id, { name = "Item " .. id, quality = 4,
            link = "|cffa335ee|Hitem:" .. id .. ":0:0:0:0:0:0:0:80|h[Raid Item " .. id .. "]|h|r" })
    end
end)

local function receive(message)
    forge.fire("CHAT_MSG_ADDON", "FLLedger", message, "RAID", "Lead")
end

local function award(id, itemID, recipient, state, spec)
    receive(table.concat({ "A", "Lead-1792131000", "Lead", id, 1, 1792131000 + id, itemID, "",
        recipient, state, 1, spec or "", 50, 1, 100, recipient, 1, "", "21:0" .. id }, ";"))
end

local function importWishes(count)
    local lines = { "WL2;Tester;1792130000;20" }
    for i = 1, count do
        table.insert(lines, string.format("%d;%s;0;%d;note %d", 40000 + i, i % 3 == 0 and "os" or "ms", i, i))
    end
    forge.click("RaidWishlistImportOpen")
    forge.type("RaidWishlistImportText", table.concat(lines, "\n"))
    forge.click("RaidWishlistImportButton")
end

local function shownText(prefix, rows)
    local texts = {}
    for i = 1, rows do
        local row = _G[prefix .. i]
        if row and row:IsShown() then table.insert(texts, row:GetText() or "") end
    end
    return table.concat(texts, "\n")
end

test("the wishlist scrolls to its last wish", function()
    forge.raid({ "Lead", "Tester" })
    forge.slash("/wish")
    importWishes(30)
    forge.click("RaidWishlistTabwish")
    expect("RaidWishlistWishPane").toBeShown()
    expect(shownText("RaidWishlistWish", 30)).toContain("Raid Item 40001")
    expect(string.find(shownText("RaidWishlistWish", 30), "Raid Item 40030", 1, true)).toBeNil()
    expect(forge.text("RaidWishlistWishPosition")).toContain("/ 30")
    forge.wheel("RaidWishlistWishPane", -30)
    expect(shownText("RaidWishlistWish", 30)).toContain("Raid Item 40030")
    expect(string.find(shownText("RaidWishlistWish", 30), "Raid Item 40001]", 1, true)).toBeNil()
    forge.wheel("RaidWishlistWishPane", 30)
    expect(shownText("RaidWishlistWish", 30)).toContain("Raid Item 40001")
    expect(forge.layoutIssues("RaidWishlistFrame")).toEqual({})
    forge.sketch("wishlist-long", RaidWishlistFrame)
end)

test("open items scroll too", function()
    local items = {}
    for i = 1, 25 do table.insert(items, (40000 + i) .. ":o:c:") end
    receive("O;Lead-1792131000;Lead;" .. table.concat(items, ","))
    forge.click("RaidWishlistTabopen")
    expect("RaidWishlistOpenPane").toBeShown()
    expect("RaidWishlistWishPane").toBeHidden()
    forge.wheel("RaidWishlistOpenPane", -30)
    expect(shownText("RaidWishlistOpen", 30)).toContain("Raid Item 40025")
    expect(forge.layoutIssues("RaidWishlistFrame")).toEqual({})
    forge.sketch("open-long", RaidWishlistFrame)
end)

test("this raid's awards scroll and name the recipient in its own column", function()
    for i = 1, 40 do award(i, 40000 + i, i % 2 == 0 and "Tester" or "Someone", "assigned", "ms") end
    forge.click("RaidWishlistTabraid")
    expect("RaidWishlistRaidPane").toBeShown()
    expect(forge.text("RaidWishlistRaid1Recipient")).toBe("Tester")
    forge.wheel("RaidWishlistRaidPane", -50)
    expect(shownText("RaidWishlistRaid", 30)).toContain("Raid Item 40001")
    expect(forge.text("RaidWishlistRaidPosition")).toContain("/ 40")
    expect(forge.layoutIssues("RaidWishlistFrame")).toEqual({})
    forge.sketch("raid-long", RaidWishlistFrame)
end)

test("the tabs count their entries", function()
    expect(forge.text("RaidWishlistTabwish")).toContain("30")
    expect(forge.text("RaidWishlistTabopen")).toContain("25")
    expect(forge.text("RaidWishlistTabraid")).toContain("40")
end)
