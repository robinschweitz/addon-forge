-- FR-RL-019: the leader's on-screen button appears when the loot method does
-- not fit: no master loot in a boss fight, master loot outside one. FR-RL-021:
-- it can be switched off. FR-RL-017/018: nothing changes the loot method on
-- its own any more.
local calls, method, masterIndex, inInstance, inCombat, bossUnit, bosses

before_load(function()
    forge.locale("deDE", {})
    calls, method, masterIndex, inInstance, inCombat, bossUnit, bosses = {}, "group", nil, true, false, false, {}
    -- Not emulated offline; the live plan RaidLedger-loot-method exercises the click.
    forge.stub("SetLootMethod", function(...) table.insert(calls, { ... }) end)
    forge.stub("GetLootMethod", function() return method, nil, masterIndex end)
    forge.stub("IsInInstance", function() return inInstance and 1 or nil, inInstance and "raid" or "none" end)
    local unitExists, unitAffectingCombat = UnitExists, UnitAffectingCombat
    forge.stub("UnitExists", function(unit)
        if unit == "boss1" then return bossUnit and 1 or nil end
        return unitExists(unit)
    end)
    forge.stub("UnitClassification", function(unit) return bosses[unit] and "worldboss" or "elite" end)
    forge.stub("UnitAffectingCombat", function(unit)
        if unit == "player" then return inCombat and 1 or nil end
        return unitAffectingCombat(unit)
    end)
end)

local function report(newMethod, index)
    method, masterIndex = newMethod, index
    forge.fire("PARTY_LOOT_METHOD_CHANGED")
end

local function combat(value)
    inCombat = value
    forge.fire(value and "PLAYER_REGEN_DISABLED" or "PLAYER_REGEN_ENABLED")
end

local function targets(unit, isBoss)
    bosses[unit] = isBoss
    if unit == "target" then forge.fire("PLAYER_TARGET_CHANGED") else forge.fire("UNIT_TARGET", "raid2") end
end

local function button() return forge.frame("RaidLedgerLootMethod") end
local function shown() return forge.shown("RaidLedgerLootMethod") end

test("FR-RL-019 only a group's leader gets the button", function()
    method = "master"
    forge.fire("PLAYER_ENTERING_WORLD")
    expect(shown()).toBe(false)
    forge.raid({ "Tester", "Alice" })
    forge.leader(false)
    forge.fire("RAID_ROSTER_UPDATE")
    expect(shown()).toBe(false)
    forge.leader(true)
    forge.fire("PARTY_LEADER_CHANGED")
    expect(shown()).toBe(true)
end)

test("FR-RL-019 master loot outside a boss fight asks for group loot; the button waits for the client", function()
    expect(forge.text("RaidLedgerLootMethod")).toBe("! BEUTE: PLÜNDERMEISTER > GRUPPE")
    local r = button():GetBackdropColor()
    expect(r > 0.5).toBe(true)
    forge.click("RaidLedgerLootMethod")
    expect(calls).toEqual({ { "group" } })
    expect(shown()).toBe(true)
    report("group")
    expect(shown()).toBe(false)
end)

test("FR-RL-019 group loot stays hidden without a boss, whatever is targeted or fought", function()
    combat(true)
    targets("target", false)
    expect(shown()).toBe(false)
    combat(false)
    expect(shown()).toBe(false)
end)

test("FR-RL-019 a targeted boss outside combat is no boss fight yet", function()
    targets("target", true)
    expect(shown()).toBe(false)
end)

test("FR-RL-019 in combat with a boss, group loot asks for master loot", function()
    combat(true)
    expect(shown()).toBe(true)
    expect(forge.text("RaidLedgerLootMethod")).toBe("! BEUTE: GRUPPE > PLÜNDERMEISTER")
    calls = {}
    forge.click("RaidLedgerLootMethod")
    expect(calls).toEqual({ { "master", "Tester" } })
    report("master", 1)
    expect(shown()).toBe(false)
end)

test("FR-RL-019 turning to an add keeps the boss fight until combat ends", function()
    targets("target", false)
    expect(shown()).toBe(false)
    combat(false)
    expect(shown()).toBe(true)
    expect(forge.text("RaidLedgerLootMethod")).toBe("! BEUTE: PLÜNDERMEISTER > GRUPPE")
end)

test("FR-RL-019 master loot in a fight with trash only asks for group loot", function()
    combat(true)
    expect(shown()).toBe(true)
    combat(false)
    report("group")
end)

test("FR-RL-019 a group member's boss target starts the boss fight", function()
    combat(true)
    expect(shown()).toBe(false)
    targets("raid2target", true)
    expect(shown()).toBe(true)
    report("master", 1)
    targets("raid2target", false)
    expect(shown()).toBe(false)
    combat(false)
    report("group")
end)

test("FR-RL-019 a boss unit counts without any target", function()
    bossUnit = true
    forge.fire("INSTANCE_ENCOUNTER_ENGAGE_UNIT")
    expect(shown()).toBe(true)
    report("master", 1)
    expect(shown()).toBe(false)
    bossUnit = false
    report("group")
end)

test("FR-RL-019 another method in a boss fight asks for master loot; outside one it stays hidden", function()
    report("freeforall")
    expect(shown()).toBe(false)
    bosses.target = true
    combat(true)
    expect(forge.text("RaidLedgerLootMethod")).toBe("! BEUTE: ANDERE > PLÜNDERMEISTER")
    calls = {}
    forge.click("RaidLedgerLootMethod")
    expect(calls).toEqual({ { "master", "Tester" } })
    bosses.target = nil
    combat(false)
    report("group")
end)

test("FR-RL-019 outside an instance nothing shows", function()
    inInstance = false
    report("master", 1)
    expect(shown()).toBe(false)
    bosses.target = true
    combat(true)
    report("group")
    expect(shown()).toBe(false)
    bosses.target = nil
    combat(false)
    inInstance = true
    forge.fire("PLAYER_ENTERING_WORLD")
end)

test("FR-RL-021 SETTINGS switches the button off and on", function()
    forge.slash("/ledger settings")
    expect(forge.text("RaidLedgerLootButtonOption")).toBe("BEUTE-KNOPF: AN")
    forge.click("RaidLedgerLootButtonOption")
    expect(forge.text("RaidLedgerLootButtonOption")).toBe("BEUTE-KNOPF: AUS")
    expect(forge.saved("RaidLedgerDB").lootButtonHidden).toBe(true)
    report("master", 1)
    expect(shown()).toBe(false)
    forge.click("RaidLedgerLootButtonOption")
    expect(shown()).toBe(true)
    forge.slash("/ledger lootbutton off")
    expect(shown()).toBe(false)
    expect(forge.text("RaidLedgerLootButtonOption")).toBe("BEUTE-KNOPF: AUS")
    forge.slash("/ledger lootbutton on")
    expect(shown()).toBe(true)
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
end)

test("FR-RL-021 lootbutton show gives the leader the switch until on or off", function()
    calls = {}
    report("group")
    expect(shown()).toBe(false)
    forge.slash("/ledger lootbutton show")
    expect(shown()).toBe(true)
    expect(forge.text("RaidLedgerLootMethod")).toBe("BEUTE: GRUPPE")
    local r = button():GetBackdropColor()
    expect(r < 0.5).toBe(true)
    forge.click("RaidLedgerLootMethod")
    expect(calls).toEqual({ { "master", "Tester" } })
    inInstance = false
    report("master", 1)
    expect(forge.text("RaidLedgerLootMethod")).toBe("BEUTE: PLÜNDERMEISTER")
    inInstance = true
    report("group")
    forge.slash("/ledger lootbutton on")
    expect(shown()).toBe(false)
end)

test("FR-RL-019 names another master looter and fits a long German name", function()
    forge.slash("/ledger lootbutton show")
    forge.raid({ "Tester", "Schattenfürst" })
    forge.leader(true)
    inInstance = false
    report("master", 2)
    expect(forge.text("RaidLedgerLootMethod")).toBe("BEUTE: PLÜNDERMEISTER (Schattenfürst)")
    forge.sketch("loot-method", "RaidLedgerLootMethod")
    expect(forge.layoutIssues("RaidLedgerLootMethod")).toEqual({})
    expect(forge.layoutIssues(UIParent)).toEqual({})
end)

test("FR-RL-019 a drag moves the button", function()
    local before = forge.rect("RaidLedgerLootMethod")
    forge.drag("RaidLedgerLootMethod", 30, -20)
    local after = forge.rect("RaidLedgerLootMethod")
    expect(after.left).toBe(before.left + 30)
    expect(after.top).toBe(before.top - 20)
    forge.slash("/ledger lootbutton on")
end)

test("FR-RL-017 a boss fight never changes the loot method", function()
    calls = {}
    report("group")
    forge.fire("INSTANCE_ENCOUNTER_ENGAGE_UNIT")
    forge.combat(true)
    forge.combat(false)
    expect(calls).toEqual({})
end)

test("FR-RL-018 SETTINGS and the slash command no longer offer automatic master loot", function()
    forge.slash("/ledger settings")
    expect(forge.frame("RaidLedgerAutoMasterLoot")).toBeNil()
    forge.slash("/ledger automaster on")
    expect(forge.saved("RaidLedgerDB").autoMasterLoot).toBeNil()
    expect(#forge.errors()).toBe(0)
end)
