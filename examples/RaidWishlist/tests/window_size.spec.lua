-- The window can be resized with the grip in its lower right corner and scaled
-- (- / + at the bottom, or /wish scale), for small and large screens: lists
-- show more rows in a taller window, and size and scale stay after /reload.
before_load(function()
    for id = 40001, 40045 do
        forge.item(id, { name = "Item " .. id, quality = 4,
            link = "|cffa335ee|Hitem:" .. id .. ":0:0:0:0:0:0:0:80|h[Schulterschutz des unerschütterlichen Wächters " .. id .. "]|h|r" })
    end
end)

local function importWishes(count)
    local lines = { "WL2;Tester;1792130000;20" }
    for i = 1, count do
        table.insert(lines, string.format("%d;%s;0;%d;Notiz für den Raidleiter %d", 40000 + i, i % 3 == 0 and "os" or "ms", i, i))
    end
    forge.click("RaidWishlistImportOpen")
    forge.type("RaidWishlistImportText", table.concat(lines, "\n"))
    forge.click("RaidWishlistImportButton")
end

local function size() return RaidWishlistFrame:GetWidth(), RaidWishlistFrame:GetHeight() end
-- The client keeps the scale as a 32-bit float (1.3 reads back as 1.2999999523163).
local function scale() return math.floor(RaidWishlistFrame:GetScale() * 100 + 0.5) / 100 end
local function shown(name) local f = forge.frame(name); return f ~= nil and f:IsVisible() end

test("the window starts at 500x440 and 100% with 17 rows", function()
    forge.raid({ "Lead", "Tester" })
    forge.slash("/wish")
    importWishes(40)
    local w, h = size()
    expect(w).toBe(500)
    expect(h).toBe(440)
    expect(scale()).toBe(1)
    expect(shown("RaidWishlistWish17")).toBe(true)
    expect(forge.frame("RaidWishlistWish18")).toBeNil()
    expect(forge.text("RaidWishlistScaleValue")).toBe("100%")
    expect(forge.layoutIssues("RaidWishlistFrame")).toEqual({})
end)

test("the grip resizes the window; lists show more rows and use the width", function()
    expect("RaidWishlistResize").toBeShown()
    local window, grip = forge.rect("RaidWishlistFrame"), forge.rect("RaidWishlistResize")
    expect(window.right - grip.right <= 6).toBe(true)
    expect(grip.bottom - window.bottom <= 6).toBe(true)
    forge.drag("RaidWishlistResize", 200, -140)      -- 8 rows of 17 px more, to the screen's bottom
    local w, h = size()
    expect(w).toBe(700)
    expect(h).toBe(580)
    expect(shown("RaidWishlistWish25")).toBe(true)
    expect(forge.frame("RaidWishlistWish26")).toBeNil()
    expect(forge.text("RaidWishlistWishPosition")).toContain("1-25 / 40")
    window = forge.rect("RaidWishlistFrame")
    expect(window.right - forge.rect("RaidWishlistWish1").right).toBe(20)
    forge.sketch("large-wishlist", RaidWishlistFrame)
    expect(forge.layoutIssues("RaidWishlistFrame")).toEqual({})
    for _, tab in ipairs({ "open", "raid" }) do
        forge.click("RaidWishlistTab" .. tab)
        expect(forge.layoutIssues("RaidWishlistFrame")).toEqual({})
    end
    forge.click("RaidWishlistImportOpen")
    expect(forge.layoutIssues("RaidWishlistFrame")).toEqual({})
    expect(window.right - forge.rect("RaidWishlistImportPanel").right).toBe(12)
    forge.click("RaidWishlistImportOpen")
    forge.click("RaidWishlistTabwish")
end)

test("the window cannot shrink below 500x440 or grow past the screen", function()
    forge.drag("RaidWishlistResize", -2000, 2000)
    local w, h = size()
    expect(w).toBe(500)
    expect(h).toBe(440)
    forge.drag("RaidWishlistResize", 4000, -4000)
    local r = forge.rect("RaidWishlistFrame")
    expect(r.right <= 1280 and r.bottom >= 0).toBe(true)
end)

test("- / + and /wish scale change the scale; out of range is refused", function()
    forge.slash("/wish reset")
    forge.click("RaidWishlistScaleDown")
    expect(scale()).toBe(0.9)
    expect(forge.text("RaidWishlistScaleValue")).toBe("90%")
    forge.click("RaidWishlistScaleUp")
    forge.click("RaidWishlistScaleUp")
    expect(scale()).toBe(1.1)
    forge.slash("/wish scale 70")
    expect(forge.saved("RaidWishlistDB").window.scale).toBe(0.7)   -- not the client's float32 read-back
    expect(scale()).toBe(0.7)
    expect(forge.text("RaidWishlistScaleValue")).toBe("70%")
    expect(math.floor(forge.rect("RaidWishlistFrame").width + 0.5)).toBe(350)
    forge.slash("/wish scale 200")
    expect(scale()).toBe(0.7)
    expect(forge.lastChat()).toContain("/wish scale")
    expect(forge.layoutIssues("RaidWishlistFrame")).toEqual({})
end)

test("size and scale stay after /reload", function()
    forge.slash("/wish scale 120")
    forge.drag("RaidWishlistResize", 34, -34)
    local w, h = size()
    w, h = math.floor(w + 0.5), math.floor(h + 0.5)   -- saved in whole pixels
    forge.reload()
    forge.slash("/wish")
    expect(scale()).toBe(1.2)
    local w2, h2 = size()
    expect(w2).toBe(w)
    expect(h2).toBe(h)
    expect(shown("RaidWishlistWish18")).toBe(true)      -- 28 px taller (34 screen px at 120%): one more row
end)

test("/wish reset brings back the default size, scale and place", function()
    forge.slash("/wish reset")
    local w, h = size()
    expect(w).toBe(500)
    expect(h).toBe(440)
    expect(scale()).toBe(1)
    expect(forge.frame("RaidWishlistWish18"):IsShown()).toBe(false)
    expect(forge.layoutIssues("RaidWishlistFrame")).toEqual({})
    expect(#forge.errors()).toBe(0)
end)
