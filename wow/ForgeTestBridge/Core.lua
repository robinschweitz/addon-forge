-- ForgeTestBridge for the ORIGINAL 3.3.5a client (Lua 5.1).
-- No arbitrary filesystem/network access, no dynamic code from external agents.
ForgeTestBridge = ForgeTestBridge or {}
local Bridge = ForgeTestBridge
Bridge.tests = Bridge.tests or {}
Bridge.errors = Bridge.errors or {}
Bridge.version = 2

local function stringify(value)
    if type(value) == "string" then return value end
    return tostring(value)
end

function Bridge:RegisterTest(suite, name, fn)
    if type(suite) ~= "string" or type(name) ~= "string" or type(fn) ~= "function" then
        error("RegisterTest(suite, name, function) expected", 2)
    end
    if not self.tests[suite] then self.tests[suite] = {} end
    table.insert(self.tests[suite], { name = name, fn = fn })
end

function Bridge:Assert(condition, message)
    if not condition then error(message or "assertion failed", 2) end
end

local function forgeUnit(unit)
    if not UnitExists(unit) then return { exists = false } end
    local _, class = UnitClass(unit)
    return { exists = true, name = UnitName(unit) or "", class = class or "",
        level = UnitLevel(unit) or 0, health = UnitHealth(unit) or 0,
        maxHealth = UnitHealthMax(unit) or 0,
        isPlayer = UnitIsPlayer(unit) and true or false }
end

Bridge.frames = Bridge.frames or {}
function Bridge:RegisterFrame(name, frame)
    if type(name) ~= "string" or not string.match(name, "^[%w_]+$")
        or string.len(name) > 32 or not frame or type(frame.IsShown) ~= "function" then
        error("RegisterFrame expects a name and WoW frame", 2)
    end
    self.frames[name] = frame
end

local function forgeSnapshot()
    local frames = {}
    for name, frame in pairs(Bridge.frames) do
        local ok, value = pcall(function()
            return { shown = frame:IsShown() and true or false,
                     width = frame:GetWidth(), height = frame:GetHeight() }
        end)
        if ok then frames[name] = value end
    end
    local party = {}
    local count = GetNumPartyMembers() or 0
    for i = 1, math.min(count, 4) do
        table.insert(party, forgeUnit("party" .. i))
    end
    return { player = forgeUnit("player"), target = forgeUnit("target"),
        party = { count = count, members = party },
        raid = { count = GetNumRaidMembers() or 0 },
        questLogCount = GetNumQuestLogEntries() or 0, frames = frames }
end

local function runSuite(suite, runId)
    local entries = Bridge.tests[suite] or {}
    local report = {
        schemaVersion = 2,
        bridgeVersion = Bridge.version,
        runId = runId,
        suite = suite,
        completed = false,
        tests = {},
        errors = {},
        client = "3.3.5a",
    }
    ForgeTestReport = report
    for i, entry in ipairs(entries) do
        local ok, problem = pcall(entry.fn)
        table.insert(report.tests, {
            name = entry.name,
            status = ok and "passed" or "failed",
            error = ok and nil or stringify(problem),
        })
    end
    for _, err in ipairs(Bridge.errors) do
        table.insert(report.errors, err)
    end
    local ok, observed = pcall(forgeSnapshot)
    if ok then report.snapshot = observed
    else table.insert(report.errors, "Snapshot: " .. stringify(observed)) end
    report.completed = true
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffForge|r " .. suite .. ": " .. #report.tests .. " assertions finished. Use /reload to persist.")
end

-- Capture unhandled Lua exceptions if the client exposes a replaceable handler.
-- If another addon takes the handler later, the runner still has pcall assertions.
local function installErrorHandler()
    if Bridge.handlerInstalled then return end
    if type(geterrorhandler) ~= "function" or type(seterrorhandler) ~= "function" then return end
    local previous = geterrorhandler()
    Bridge.handlerInstalled = true
    seterrorhandler(function(message)
        table.insert(Bridge.errors, stringify(message))
        if type(previous) == "function" then pcall(previous, message) end
    end)
end

SLASH_FORGETEST1 = "/forge"
SlashCmdList["FORGETEST"] = function(msg)
    local suite, id = string.match(msg or "", "^run%s+(%w+)%s+(%w+)%s*$")
    local expected = string.match(msg or "", "^expect%s+(%a+)%s*$")
    if expected then
        Bridge.expectedPeer = expected
        DEFAULT_CHAT_FRAME:AddMessage("Forge expected peer: " .. expected)
    elseif suite and id then
        runSuite(suite, id)
    else
        DEFAULT_CHAT_FRAME:AddMessage("Usage: /forge run smoke RUN_ID, then /reload")
    end
end

installErrorHandler()

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self)
    installErrorHandler()
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffForgeTestBridge|r loaded. /forge run smoke RUN_ID")
end)

Bridge:RegisterTest("smoke", "bridge_loaded", function()
    Bridge:Assert(type(CreateFrame) == "function", "CreateFrame API is unavailable")
    Bridge:Assert(type(UnitName("player")) == "string", "Player is not in the world")
end)

-- Client-side oracle for a synchronized protocol peer, not a mock Unit API.
Bridge:RegisterTest("peer", "peer_target_visible", function()
    Bridge:Assert(type(Bridge.expectedPeer) == "string", "No expected peer configured")
    Bridge:Assert(UnitExists("target"), "Expected peer is not targeted")
    local actual = UnitName("target")
    Bridge:Assert(actual == Bridge.expectedPeer,
        "Wrong peer selected: " .. tostring(actual) .. " expected " .. Bridge.expectedPeer)
    Bridge:Assert(UnitIsPlayer("target"), "Target is not a player")
end)
