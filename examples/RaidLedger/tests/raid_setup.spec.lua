-- Raid setup, taken over from RaidSync: read the website's invite list,
-- invite (and retry the missing), sort groups by role, export attendance.
local INVITES = "RS2;INV;42;ICC 25 Mittwoch;25\n"
    .. "Tank;TANK;Krieger;0\nHealer;HEAL;Priester;0\nDamage;DD;Magier;0\nStandby;DD;Jäger;1\nkaputt"

before_load(function()
    forge.locale("enUS", {
        ERR_DECLINE_GROUP_S = "%s declines your group invitation.",
        ERR_BAD_PLAYER_NAME_S = "Cannot find player '%s'.",
        ERR_ALREADY_IN_GROUP_S = "%s is already in a group.",
        ERR_JOINED_GROUP_S = "%s joins the party.",
        ERR_RAID_MEMBER_ADDED_S = "%s has joined the raid group.",
        ERR_INVITE_PLAYER_S = "You have invited %s to join your group.",
    })
end)

local invited, moves = {}, {}
local function stubGroupAPI()
    -- Not emulated offline; the live raid-setup plan exercises the real ones.
    forge.stub("InviteUnit", function(name) table.insert(invited, name) end)
    forge.stub("ConvertToRaid", function() end)
    forge.stub("SwapRaidSubgroup", function(a, b) table.insert(moves, "swap " .. a .. " " .. b) end)
    forge.stub("SetRaidSubgroup", function(index, group) table.insert(moves, "set " .. index .. " " .. group) end)
    forge.stub("IsInGuild", function() return 1 end)
    forge.stub("GetNumGuildMembers", function() return 1 end)
    forge.stub("GetGuildRosterInfo", function() return "Damage", "", 0, 80, "Mage", "", "", "", nil end)
end

local function chatHas(text)
    for _, line in ipairs(forge.chat()) do
        if line == "RaidLedger: " .. text then return true end
    end
    return false
end

test("RAID opens the raid setup in place of the panes", function()
    stubGroupAPI()
    forge.click("RaidLedgerRaidButton")
    expect("RaidLedgerRaidPanel").toBeShown()
    expect(forge.findText("RAID SETUP")).toBeTruthy()
    expect(forge.findText("No invite list read yet.")).toBeTruthy()
    expect(forge.findText("MASTER LOOT ITEMS")).toBeNil()
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
end)

test("READ refuses other text and reads the website's invite list", function()
    forge.type("RaidLedgerInviteText", "RS1|INV|42|ICC|25\nTank|TANK|Krieger|0")   -- RaidSync's old list
    forge.clickText("READ")
    expect(chatHas("That is not the website's invite list.")).toBe(true)
    forge.type("RaidLedgerInviteText", INVITES)
    forge.clickText("READ")
    expect(chatHas("skipped line: kaputt")).toBe(true)
    expect(chatHas("4 characters read for raid #42.")).toBe(true)
    expect(forge.findText("Raid #42 ICC 25 Mittwoch: 0 / 4 in the raid")).toBeTruthy()
    expect(forge.findText("Tank  Tank")).toBeTruthy()
    expect(forge.findText("bench")).toBeTruthy()                  -- Standby stays home
    expect(forge.saved("RaidLedgerDB").raidID).toBe(42)      -- the loot export uses the same raid
end)

test("INVITE ALL invites the list in order, skipping the bench and offline guild members", function()
    forge.leader(true)
    forge.clickText("INVITE ALL")
    expect(chatHas("Inviting 2 characters.")).toBe(true)
    forge.advance(1, 0.1)
    expect(invited).toEqual({ "Tank", "Healer" })
    expect(chatHas("All invites sent.")).toBe(true)
    expect(forge.findText("offline")).toBeTruthy()                -- Damage, per the guild roster
    expect(#forge.errors()).toBe(0)
end)

test("system messages and the roster update each player's status", function()
    forge.fire("CHAT_MSG_SYSTEM", "Healer declines your group invitation.")
    expect(forge.findText("declined")).toBeTruthy()
    forge.raid({ { name = "Tester", subgroup = 1, classToken = "PALADIN" }, { name = "Tank", subgroup = 2, classToken = "WARRIOR" } })
    expect(forge.findText("Raid #42 ICC 25 Mittwoch: 1 / 4 in the raid")).toBeTruthy()
end)

test("RETRY MISSING asks the declined again, not the raid or the offline", function()
    forge.clickText("RETRY MISSING")
    forge.advance(1, 0.1)
    expect(invited).toEqual({ "Tank", "Healer", "Healer" })
end)

test("the bench is invited once BENCH is switched on", function()
    forge.clickText("BENCH: NO")
    expect(forge.findText("BENCH: YES")).toBeTruthy()
    forge.clickText("INVITE ALL")
    forge.advance(1, 0.1)
    expect(invited[#invited]).toBe("Standby")
end)

test("SORT GROUPS puts tanks, then healers, then the rest into groups of five", function()
    local raid = { { name = "Tester", subgroup = 1 } }
    for i = 1, 4 do table.insert(raid, { name = "Dps" .. i, subgroup = 1 }) end
    table.insert(raid, { name = "Healer", subgroup = 2 })
    table.insert(raid, { name = "Tank", subgroup = 2 })
    forge.raid(raid)
    forge.clickText("SORT GROUPS")
    -- Group 1 becomes Tank, Healer, Dps1-3: Tester and Dps4 swap with them.
    expect(moves).toEqual({ "swap 1 6", "swap 5 7" })
    expect(chatHas("2 players moved (tanks, healers, the rest).")).toBe(true)
end)

test("attendance lists everyone seen in the raid, also those who left", function()
    forge.raid({ { name = "Tester", classToken = "PALADIN" }, { name = "Latejoin", classToken = "MAGE" } })
    forge.click("RaidLedgerAttendance")
    local text = forge.text("RaidLedgerRosterText")
    expect(string.match(text, "^RS2;ROSTER;42;Tester;%d+\n")).toBeTruthy()
    expect(text).toContain("\nTank;WARRIOR;")
    expect(text).toContain("\nLatejoin;MAGE;")
    expect(text).toContain("\nDps1;WARRIOR;")
    expect(forge.findText("Attendance selected: press Ctrl+C and paste it into the raid website's roster import.")).toBeTruthy()
end)

test("a list for another raid starts a new attendance; BACK returns to the panes", function()
    forge.type("RaidLedgerInviteText", "RS2;INV;43;Naxx;10\nTank;TANK;Krieger;0")
    forge.clickText("READ")
    forge.raid({ { name = "Tester", classToken = "PALADIN" } })
    forge.click("RaidLedgerAttendance")
    local text = forge.text("RaidLedgerRosterText")
    expect(string.match(text, "^RS2;ROSTER;43;")).toBeTruthy()
    expect(string.find(text, "Latejoin", 1, true)).toBeNil()
    forge.clickText("BACK")
    expect("RaidLedgerRaidPanel").toBeHidden()
    expect(forge.findText("MASTER LOOT ITEMS")).toBeTruthy()
end)

test("only the raid lead or an assistant can invite or sort", function()
    forge.leader(false)
    forge.slash("/ledger invite")
    expect(chatHas("Only the raid lead or an assistant can invite.")).toBe(true)
    forge.slash("/ledger groups")
    expect(chatHas("Sorting groups only works in a raid, as raid lead or assistant.")).toBe(true)
    forge.slash("/ledger help")
    expect(chatHas("/ledger attendance - export who was in the raid for the website")).toBe(true)
    expect(#forge.errors()).toBe(0)
end)

test("a party that cannot become a raid (below level 10) still invites while there is room", function()
    forge.leader(true)
    forge.raid({})
    forge.party({ "Tank" })
    forge.slash("/ledger setup")
    forge.type("RaidLedgerInviteText", "RS2;INV;44;Low;10\nTank;TANK;Krieger;0\nHealer;HEAL;Priester;0")
    forge.clickText("READ")
    local before = #invited
    forge.slash("/ledger invite")
    forge.advance(5, 0.1)                    -- three conversion attempts that the server ignores
    expect(chatHas("The group did not become a raid: everyone must be level 10 or higher.")).toBe(true)
    expect(invited[before + 1]).toBe("Healer")
    expect(chatHas("All invites sent.")).toBe(true)
end)
