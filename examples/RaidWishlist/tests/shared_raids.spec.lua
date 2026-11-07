-- FR-RW-011: a raid shared from RaidLedger's VERLAUF (A lines marked 2) is
-- kept as a past raid and never changes the raid the wishlist follows.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local MONDAY, TODAY = "Kuehl-1792131000", "Lead-1792735000"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
end)

local function db() return forge.saved("RaidWishlistDB") end

local function receive(message, sender)
    forge.fire("CHAT_MSG_ADDON", "FLLedger", message, "RAID", sender or "Lead")
end

test("FR-RW-011 a shared older raid becomes a past raid and today stays followed", function()
    forge.raid({ "Lead", "Tester" })
    forge.slash("/wish")
    forge.click("RaidWishlistImportOpen")
    forge.type("RaidWishlistImportText", "WL2;Tester;1792130000;20\n20513;ms;1;1;BiS")
    forge.click("RaidWishlistImportButton")
    receive("A;" .. TODAY .. ";Lead;1;1;1792735100;20513;;Lead;given;1;ms;30;1;100;Lead;1;;20:10")
    receive("A;" .. MONDAY .. ";Kuehl;7;1;1792131007;20513;;Tester;given;1;ms;50;1;100;Tester;1;;21:07;2")
    receive("A;" .. MONDAY .. ";Kuehl;8;1;1792131100;20513;;Lead;given;1;os;40;1;100;Lead;1;;21:09;2")
    expect(db().raid.session).toBe(TODAY)
    expect(db().pastRaids[1].session).toBe(MONDAY)
    expect(db().pastRaids[1].awards["kuehl:7"].recipient).toBe("Tester")
    expect(forge.findText("RECEIVED")).toBeNil()          -- Monday's crest is not today's
    local told = 0
    for _, line in ipairs(forge.chat()) do
        if string.find(line, "Lead shared the raid of", 1, true) then told = told + 1 end
    end
    expect(told).toBe(1)
    forge.click("RaidWishlistTabraid")
    forge.click("RaidWishlistRaidOlder")
    expect(RaidWishlistRaidPane.heading:GetText()).toContain("(2)")
end)

test("FR-RW-011 a shared newer raid does not take over either", function()
    receive("A;Lead-1793000000;Lead;3;1;1793000100;20513;;Lead;given;1;ms;30;1;100;Lead;1;;20:10;2")
    expect(db().raid.session).toBe(TODAY)
    expect(db().pastRaids[1].session).toBe("Lead-1793000000")   -- date order, newest first
    expect(db().pastRaids[2].session).toBe(MONDAY)
end)
