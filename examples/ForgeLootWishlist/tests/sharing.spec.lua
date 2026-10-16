-- The member's wishlist goes to the raid lead's ledger ("W" messages): after
-- an import, after login and whenever a ledger asks ("WQ"). /flw share off
-- stops it.
local function wishMessages()
    local list = {}
    for _, m in ipairs(forge.addonMessages()) do
        if string.sub(m.message, 1, 2) == "W;" then table.insert(list, m.message) end
    end
    return list
end

local function ask()
    forge.fire("CHAT_MSG_ADDON", "FLLedger", "WQ;Lead", "RAID", "Lead")
end

test("an import shares the new list with the group a moment later", function()
    forge.raid({ "Lead", "Alice" })
    forge.slash("/flw import")
    forge.type("ForgeLootWishlistImportText", "WL2;Tester;1792130000;0\n20513;ms;1;1;\n21281;os;0;2;")
    forge.click("ForgeLootWishlistImportButton")
    expect(#wishMessages()).toBe(0)
    forge.advance(1.5, 0.2)
    expect(wishMessages()).toEqual({ "W;1792130000;1;1;20513:m:1:1,21281:o:0:2" })
end)

test("a ledger's request is answered once, after a spread-out delay", function()
    local before = #wishMessages()
    ask()
    ask()                                   -- a second ledger asking at the same time
    expect(#wishMessages()).toBe(before)
    forge.advance(6, 0.2)
    expect(#wishMessages()).toBe(before + 1)
end)

test("a long wishlist is split into parts of 15 items", function()
    local lines = { "WL2;Tester;1792140000;0" }
    for i = 1, 20 do table.insert(lines, (30000 + i) .. ";ms;0;" .. i .. ";") end
    forge.slash("/flw import")
    forge.type("ForgeLootWishlistImportText", table.concat(lines, "\n"))
    forge.click("ForgeLootWishlistImportButton")
    forge.advance(1.5, 0.2)
    local sent = wishMessages()
    local first, second = sent[#sent - 1], sent[#sent]
    expect(string.match(first, "^W;1792140000;1;2;")).toBeTruthy()
    expect(select(2, string.gsub(first, ",", ","))).toBe(14)       -- 15 items
    expect(string.match(second, "^W;1792140000;2;2;30016:m:0:16,")).toBeTruthy()
    for _, message in ipairs(sent) do expect(string.len("FLLedger" .. message) <= 254).toBe(true) end
end)

test("/flw share off stops sharing; on shares again", function()
    forge.slash("/flw share off")
    expect(forge.chat()).toContain("ForgeLootWishlist: your wishlist is no longer shared.")
    local before = #wishMessages()
    ask()
    forge.advance(6, 0.2)
    expect(#wishMessages()).toBe(before)
    forge.slash("/flw share on")
    forge.advance(1.5, 0.2)
    expect(#wishMessages()).toBe(before + 2)                  -- both parts
end)
