-- ForgeTestBridge for the ORIGINAL 3.3.5a client (Lua 5.1).
-- No arbitrary filesystem/network access, no dynamic code from external agents.
ForgeTestBridge = ForgeTestBridge or {}
local Bridge = ForgeTestBridge
Bridge.tests = Bridge.tests or {}
Bridge.errors = Bridge.errors or {}
Bridge.errorCounts = Bridge.errorCounts or {}
local MAX_UNIQUE_ERRORS = 50

-- A handler error can repeat every frame; keep each distinct message once with
-- a count so the report stays small and keeps its chat/event evidence.
local function recordError(message)
    local text = string.sub(tostring(message), 1, 400)
    local counts = Bridge.errorCounts
    if counts[text] then
        counts[text] = counts[text] + 1
    elseif #Bridge.errors < MAX_UNIQUE_ERRORS then
        counts[text] = 1
        table.insert(Bridge.errors, text)
    else
        Bridge.errorsDropped = (Bridge.errorsDropped or 0) + 1
    end
end
Bridge.version = 3

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

-- Bounded observation buffers, filled from load so plans can check what the
-- addon printed and which events fired before the suite ran.
Bridge.chat = Bridge.chat or {}
Bridge.eventCounts = Bridge.eventCounts or {}
local MAX_CHAT, MAX_EVENTS, eventKinds = 40, 400, 0

local function recordChat(_, text)
    if type(text) ~= "string" then return end
    table.insert(Bridge.chat, string.sub(text, 1, 240))
    if #Bridge.chat > MAX_CHAT then table.remove(Bridge.chat, 1) end
end

local counter = CreateFrame("Frame")
counter:RegisterAllEvents()
counter:SetScript("OnEvent", function(_, event)
    local counts = Bridge.eventCounts
    if counts[event] then counts[event] = counts[event] + 1
    elseif eventKinds < MAX_EVENTS then counts[event] = 1; eventKinds = eventKinds + 1 end
end)

-- Read a dotted global path such as "MyAddonDB.history.1.item" without calling code.
function Bridge:Read(path)
    if type(path) ~= "string" or not string.match(path, "^[%a_][%w_]*[%w_%.]*$") then return nil end
    local value = _G
    for part in string.gmatch(path, "[^%.]+") do
        if type(value) ~= "table" then return nil end
        value = value[tonumber(part) or part]
    end
    if type(value) == "table" or type(value) == "function" or type(value) == "userdata" then
        return "<" .. type(value) .. ">"
    end
    return value
end

local function json(value, depth)
    local kind = type(value)
    if kind == "nil" then return "null" end
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return "null" end
        return string.format("%.14g", value)
    end
    if kind == "string" then
        return '"' .. string.gsub(value, '[%c"\\]', function(c)
            if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" end
            return string.format("\\u%04x", string.byte(c))
        end) .. '"'
    end
    if kind ~= "table" or (depth or 0) > 6 then return '"<' .. kind .. '>"' end
    local parts, n = {}, #value
    if n > 0 then
        for i = 1, n do parts[i] = json(value[i], (depth or 0) + 1) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    for k, v in pairs(value) do
        if type(k) == "string" or type(k) == "number" then
            table.insert(parts, json(tostring(k)) .. ":" .. json(v, (depth or 0) + 1))
        end
    end
    return "{" .. table.concat(parts, ",") .. "}"
end
Bridge.json = json

local function forgeSnapshot()
    local frames = {}
    for name, frame in pairs(Bridge.frames) do
        local ok, value = pcall(function()
            local text = type(frame.GetText) == "function" and frame:GetText() or nil
            return { shown = frame:IsShown() and true or false,
                     visible = frame:IsVisible() and true or false,
                     width = frame:GetWidth(), height = frame:GetHeight(),
                     text = type(text) == "string" and string.sub(text, 1, 240) or nil }
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

local function runSuite(suite, runId, paths)
    local entries = Bridge.tests[suite] or {}
    local report = {
        schemaVersion = 3,
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
            error = (not ok) and stringify(problem) or nil,
        })
    end
    for _, err in ipairs(Bridge.errors) do
        table.insert(report.errors, err)
    end
    report.errorCounts = Bridge.errorCounts
    report.errorsDropped = Bridge.errorsDropped
    local ok, observed = pcall(forgeSnapshot)
    if ok then
        observed.chat, observed.events, observed.values = {}, Bridge.eventCounts, {}
        for i, line in ipairs(Bridge.chat) do observed.chat[i] = line end
        for _, path in ipairs(paths or {}) do observed.values[path] = Bridge:Read(path) end
        report.snapshot = observed
    else table.insert(report.errors, "Snapshot: " .. stringify(observed)) end
    report.completed = true
    return report
end

-- SDK transport: run a suite and return the report as JSON in the same call.
-- No /reload or SavedVariables round trip; bounded so the pipe reply stays small.
function Bridge:RunJSON(suite, runId, paths)
    if type(suite) ~= "string" or not string.match(suite, "^%w+$")
        or type(runId) ~= "string" or not string.match(runId, "^%w+$") then
        return json({ completed = false, error = "invalid suite or run id" })
    end
    local report = runSuite(suite, runId, paths)
    local encoded = json(report)
    -- Shed the least important evidence first: chat, then error counts, then events.
    if string.len(encoded) > 28000 and report.snapshot then
        report.snapshot.chat, report.truncated = {}, true
        encoded = json(report)
    end
    if string.len(encoded) > 28000 then
        report.errorCounts = nil
        encoded = json(report)
    end
    if string.len(encoded) > 28000 and report.snapshot then
        report.snapshot.events = {}
        encoded = json(report)
    end
    return encoded
end

-- Capture unhandled Lua exceptions if the client exposes a replaceable handler.
-- If another addon takes the handler later, the runner still has pcall assertions.
local function installErrorHandler()
    if Bridge.handlerInstalled then return end
    if type(geterrorhandler) ~= "function" or type(seterrorhandler) ~= "function" then return end
    local previous = geterrorhandler()
    Bridge.handlerInstalled = true
    seterrorhandler(function(message)
        recordError(stringify(message))
        if type(previous) == "function" then pcall(previous, message) end
    end)
end

-- Typed transport (Linux/Wine): '/forge watch PATH' adds a global path for the
-- next '/forge run' to read, one per line because a chat line holds 255 characters.
Bridge.watched = Bridge.watched or {}
local MAX_WATCHED = 64

SLASH_FORGETEST1 = "/forge"
SlashCmdList["FORGETEST"] = function(msg)
    local suite, id = string.match(msg or "", "^run%s+(%w+)%s+(%w+)%s*$")
    local expected = string.match(msg or "", "^expect%s+(%a+)%s*$")
    local watch = string.match(msg or "", "^watch%s+([%w_%.]+)%s*$")
    if expected then
        Bridge.expectedPeer = expected
        DEFAULT_CHAT_FRAME:AddMessage("Forge expected peer: " .. expected)
    elseif watch then
        if #Bridge.watched < MAX_WATCHED and string.match(watch, "^[%a_][%w_]*[%w_%.]*$") then
            table.insert(Bridge.watched, watch)
        end
    elseif suite and id then
        local paths = Bridge.watched
        Bridge.watched = {}
        local report = runSuite(suite, id, paths)
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffForge|r " .. suite .. ": " .. #report.tests .. " assertions finished. Use /reload to persist.")
    else
        DEFAULT_CHAT_FRAME:AddMessage("Usage: /forge run smoke RUN_ID, then /reload")
    end
end

installErrorHandler()

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self)
    installErrorHandler()
    hooksecurefunc(DEFAULT_CHAT_FRAME, "AddMessage", recordChat)
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
