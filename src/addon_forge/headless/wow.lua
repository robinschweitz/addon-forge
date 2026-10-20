-- Headless WoW 3.3.5a environment for offline addon specs (Lua 5.1).
--
-- Emulates the parts of the client an addon touches at load and in common
-- flows: widgets, events, OnUpdate time, slash commands, chat, units, groups,
-- loot and SavedVariables. It is NOT the real client: anything it does not
-- emulate is reported (nil globals, unemulated widget methods) so a spec can
-- stub it, and real-client acceptance remains the final gate.
--
-- Loaded by addon_forge.headless with dangerous libraries already captured
-- here and removed from the global table before any addon code runs.

local os_date, os_time, os_clock = os.date, os.time, os.clock
local sethook, traceback, getinfo = debug.sethook, debug.traceback, debug.getinfo
local real_loadstring, real_setfenv = loadstring, setfenv
local rawget, rawset, pairs, ipairs, type, tostring, select, unpack, next =
      rawget, rawset, pairs, ipairs, type, tostring, select, unpack, next
local sformat, sgsub, sfind, smatch, ssub, slower, supper, srep =
      string.format, string.gsub, string.find, string.match, string.sub, string.lower, string.upper, string.rep
local tinsert, tremove, tsort, tconcat = table.insert, table.remove, table.sort, table.concat
local floor = math.floor

-- Sandbox: no host access from addon or spec code.
for _, name in ipairs({ "os", "io", "package", "require", "dofile", "loadfile", "module", "python", "debug" }) do
    _G[name] = nil
end

local H = { budget = 20000000 }

-- WoW's format() accepts positional specifiers ("%1$s") used by localized
-- GlobalStrings such as deDE RANDOM_ROLL_RESULT; plain Lua 5.1 does not.
local function wowFormat(fmt, ...)
    if type(fmt) ~= "string" or not sfind(fmt, "%%%d+%$") then return sformat(fmt, ...) end
    local args, ordered, count = { ... }, {}, 0
    local plain = sgsub(fmt, "%%(%d+)%$", function(n)
        count = count + 1
        ordered[count] = args[tonumber(n)]
        return "%"
    end)
    return sformat(plain, unpack(ordered, 1, count))
end
string.format = wowFormat

---------------------------------------------------------------- JSON
local function json(value, depth, seen)
    depth = depth or 0
    local kind = type(value)
    if kind == "nil" then return "null" end
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return "null" end
        if value == floor(value) and value > -1e15 and value < 1e15 then return sformat("%d", value) end
        return sformat("%.14g", value)
    end
    if kind == "string" then
        return '"' .. sgsub(value, '[%c"\\]', function(c)
            local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
            return map[c] or sformat("\\u%04x", c:byte())
        end) .. '"'
    end
    if kind ~= "table" or depth > 10 then return '"<' .. kind .. '>"' end
    seen = seen or {}
    if seen[value] then return '"<cycle>"' end
    seen[value] = true
    local n, count = #value, 0
    for _ in pairs(value) do count = count + 1 end
    local parts = {}
    if n > 0 and n == count then
        for i = 1, n do parts[i] = json(value[i], depth + 1, seen) end
        seen[value] = nil
        return "[" .. tconcat(parts, ",") .. "]"
    end
    for k, v in pairs(value) do
        if type(k) == "string" or type(k) == "number" then
            parts[#parts + 1] = json(tostring(k)) .. ":" .. json(v, depth + 1, seen)
        end
    end
    tsort(parts)
    seen[value] = nil
    return "{" .. tconcat(parts, ",") .. "}"
end
H.json = json

local function deepcopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local copy = {}
    seen[value] = copy
    for k, v in pairs(value) do copy[deepcopy(k, seen)] = deepcopy(v, seen) end
    return copy
end

local function where(level)
    local info = getinfo(level, "Sl")
    if not info then return "?" end
    return sgsub(info.source or "?", "^@", "") .. ":" .. tostring(info.currentline or 0)
end

---------------------------------------------------------------- report state
local report = { load_errors = {}, errors = {}, tests = {}, nil_globals = {},
                 unemulated_methods = {}, missing_methods = {}, unknown_templates = {}, modern_events = {} }
local currentTest

local function recordError(message)
    local entry = tostring(message)
    if currentTest then tinsert(currentTest.errors, entry) else tinsert(report.errors, entry) end
end

local function shortTrace(e)
    local lines = {}
    for line in string.gmatch(traceback(tostring(e), 2), "[^\n]+") do
        if #lines == 0 or (not sfind(line, "wow.lua", 1, true) and not sfind(line, "%[C%]")) then tinsert(lines, line) end
        if #lines >= 6 then break end
    end
    return tconcat(lines, "\n")
end

local budgetDepth = 0
local function budgeted(fn, ...)
    local args, n = { ... }, select("#", ...)
    budgetDepth = budgetDepth + 1
    if budgetDepth == 1 then
        sethook(function() error("forge: instruction budget exceeded (infinite loop?)", 2) end, "", H.budget)
    end
    local ok, err = xpcall(function() return fn(unpack(args, 1, n)) end, shortTrace)
    budgetDepth = budgetDepth - 1
    if budgetDepth == 0 then sethook() end
    return ok, err
end

---------------------------------------------------------------- world (rebuilt on reload)
local W        -- current world: frames, events, env
local state = setmetatable({}, { __mode = "k" })   -- widget -> private state

local Methods = {}  -- type -> method table (with inheritance)
local function class(name, parent)
    local m = setmetatable({}, { __index = parent and Methods[parent] or nil })
    Methods[name] = m
    return m
end

local METHOD_PREFIX = { "Set", "Get", "Is", "Has", "Enable", "Disable", "Register", "Unregister", "Create",
    "Clear", "Add", "Start", "Stop", "Can", "Lock", "Unlock", "Toggle", "Update", "Insert", "Highlight",
    "Play", "Raise", "Lower", "Scroll", "Refresh", "Adjust" }

local function looksLikeMethod(key)
    if type(key) ~= "string" then return false end
    for _, p in ipairs(METHOD_PREFIX) do
        if sfind(key, "^" .. p .. "%u") or key == p then return true end
    end
    return false
end

local objectMeta = {}
objectMeta.__index = function(obj, key)
    local s = state[obj]
    -- With a client method dump, a method the real widget type lacks is nil,
    -- so calling it fails here exactly like in the 3.3.5a client.
    local known = s and W.knownMethods and W.knownMethods[s.type]
    if known and type(key) == "string" and not known[key] and (Methods[s.type][key] or looksLikeMethod(key)) then
        local label = s.type .. ":" .. key
        if not report.missing_methods[label] then report.missing_methods[label] = where(3) end
        return nil
    end
    local m = s and Methods[s.type] and Methods[s.type][key]
    if m then return m end
    if s and looksLikeMethod(key) then
        local label = s.type .. ":" .. key
        if not report.unemulated_methods[label] then report.unemulated_methods[label] = where(3) end
        return function() return nil end
    end
    return nil
end

local function runScript(obj, script, ...)
    local s = state[obj]
    local fn = s and s.scripts[script]
    if not fn then return end
    local ok, err = budgeted(fn, obj, ...)
    if not ok then recordError(script .. ": " .. tostring(err)) end
    for _, hook in ipairs(s.hooks[script] or {}) do
        local hok, herr = budgeted(hook, obj, ...)
        if not hok then recordError(script .. " hook: " .. tostring(herr)) end
    end
end
H.runScript = runScript

local function newObject(kind, name, parent)
    local obj = setmetatable({}, objectMeta)
    state[obj] = { type = kind, name = name, parent = parent, shown = true, points = {}, scripts = {},
                   hooks = {}, events = {}, children = {}, regions = {}, alpha = 1, scale = 1,
                   enabled = true, attributes = {} }
    if parent and state[parent] then tinsert(state[parent].children, obj) end
    if name then W.env[name] = obj end
    tinsert(W.objects, obj)
    return obj
end

local function resolveName(name, parent)
    if type(name) ~= "string" then return nil end
    if sfind(name, "$parent", 1, true) then
        local pname = parent and state[parent] and state[parent].name or ""
        name = sgsub(name, "%$parent", pname)
    end
    return name
end

-- Region
local Region = class("Region")
function Region:GetName() return state[self].name end
function Region:GetObjectType() return state[self].type end
function Region:IsObjectType(t) local m = Methods[state[self].type]; while m do if m == Methods[t] then return true end; m = getmetatable(m) and getmetatable(m).__index end return false end
function Region:GetParent() return state[self].parent end
-- SetParent moves the object between its parents' lists, like the client:
-- otherwise a re-parented frame is missing from GetChildren, layoutIssues
-- and sketches of its new parent.
-- OnShow/OnHide follow visibility, not the shown flag (client
-- CSimpleFrame::ShowThis/HideThis): a frame becoming visible shows its shown
-- children first, then runs its own OnShow; Show() under a hidden parent runs
-- nothing until the parent appears.
local function becameVisible(obj)
    for _, kid in ipairs(state[obj].children) do
        if state[kid].shown then becameVisible(kid) end
    end
    runScript(obj, "OnShow")
end
local function becameHidden(obj)
    for _, kid in ipairs(state[obj].children) do
        if state[kid].shown then becameHidden(kid) end
    end
    runScript(obj, "OnHide")
end

function Region:SetParent(p)
    local s = state[self]
    -- Re-parenting a visible frame hides it, then shows it again under the new
    -- parent if that one is visible (client CSimpleFrame::SetParent).
    local wasVisible = self:IsVisible()
    local old = s.parent and state[s.parent]
    local list = "children"
    if old then
        for _, key in ipairs({ "children", "regions" }) do
            for i = #old[key], 1, -1 do
                if old[key][i] == self then
                    tremove(old[key], i)
                    list = key
                end
            end
        end
    end
    if wasVisible then becameHidden(self) end
    s.parent = p
    if p and state[p] then tinsert(state[p][list], self) end
    if s.shown and self:IsVisible() then becameVisible(self) end
end
function Region:Show()
    local s = state[self]
    local wasVisible = self:IsVisible()
    s.shown = true
    if not wasVisible and self:IsVisible() then becameVisible(self) end
end
function Region:Hide()
    local s = state[self]
    local wasVisible = self:IsVisible()
    s.shown = false
    if wasVisible then becameHidden(self) end
end
function Region:IsShown() return state[self].shown and true or false end
function Region:IsVisible()
    local obj = self
    while obj do
        local s = state[obj]
        if not s or not s.shown then return false end
        obj = s.parent
    end
    return true
end
function Region:SetWidth(w) state[self].width = w end
function Region:SetHeight(h) state[self].height = h end
function Region:SetSize(w, h) state[self].width, state[self].height = w, h end
function Region:GetWidth() return state[self].width or 0 end
function Region:GetHeight() return state[self].height or 0 end
function Region:GetSize() return self:GetWidth(), self:GetHeight() end
function Region:SetPoint(point, rel, relPoint, x, y)
    if type(rel) == "number" then rel, relPoint, x, y = nil, nil, rel, relPoint end
    if type(rel) == "string" then rel = W.env[rel] end
    tinsert(state[self].points, { point, rel or state[self].parent, relPoint or point, x or 0, y or 0 })
end
function Region:SetAllPoints(rel) local s = state[self]; s.points = { { "TOPLEFT", rel or s.parent }, { "BOTTOMRIGHT", rel or s.parent } } end
function Region:ClearAllPoints() state[self].points = {} end
function Region:GetNumPoints() return #state[self].points end
function Region:GetPoint(i) local p = state[self].points[i or 1]; if p then return unpack(p, 1, 5) end end
function Region:SetAlpha(a) state[self].alpha = a end
function Region:GetAlpha() return state[self].alpha end
function Region:SetDrawLayer(layer) state[self].layer = layer end

---------------------------------------------------------------- layout
-- Resolves anchors into rectangles (WoW coordinates: y grows upward, UIParent
-- is 1280x720). FontString sizes are estimated from text length and font size,
-- so layout checks catch overlaps and overflow, not exact pixels.
local POINT_X = { TOPLEFT = "L", LEFT = "L", BOTTOMLEFT = "L", TOP = "C", CENTER = "C", BOTTOM = "C",
                  TOPRIGHT = "R", RIGHT = "R", BOTTOMRIGHT = "R" }
local POINT_Y = { TOPLEFT = "T", TOP = "T", TOPRIGHT = "T", LEFT = "C", CENTER = "C", RIGHT = "C",
                  BOTTOMLEFT = "B", BOTTOM = "B", BOTTOMRIGHT = "B" }
local FONT_SIZES = { GameFontNormalSmall = 10, GameFontHighlightSmall = 10, GameFontDisableSmall = 10,
                     GameFontNormal = 12, GameFontHighlight = 12, GameFontDisable = 12,
                     GameFontNormalLarge = 16, GameFontHighlightLarge = 16, ChatFontNormal = 14 }

local function plainText(text)
    text = sgsub(text or "", "|c%x%x%x%x%x%x%x%x", "")
    text = sgsub(text, "|r", "")
    text = sgsub(text, "|H.-|h(.-)|h", "%1")
    return text
end

local function fontSize(obj)
    local s = state[obj]
    if s.font and tonumber(s.font[2]) then return tonumber(s.font[2]) end
    local fo = s.fontObject
    if type(fo) == "string" then return FONT_SIZES[fo] or 12 end
    if fo and state[fo] then return tonumber(state[fo].font and state[fo].font[2]) or FONT_SIZES[state[fo].name] or 12 end
    return 12
end

-- Width of the longest explicit line ("\n") and the number of explicit lines.
local function textWidth(obj)
    local widest, lines = 0, 0
    for line in string.gmatch(plainText(state[obj].text) .. "\n", "([^\n]*)\n") do
        lines = lines + 1
        if #line > widest then widest = #line end
    end
    return widest * fontSize(obj) * 0.6, math.max(lines, 1)
end

local resolving = {}
local function rectOf(obj)
    local s = state[obj]
    if not s then return nil end
    if obj == W.env.UIParent then return { l = 0, t = 720, r = 1280, b = 0 } end
    if #s.points == 0 or resolving[obj] then return nil end
    resolving[obj] = true
    local L, R, T, B, CX, CY
    for _, p in ipairs(s.points) do
        local rel = p[2] or W.env.UIParent
        local rr = rectOf(rel)
        if rr then
            local rp = p[3] or p[1]
            local x = (POINT_X[rp] == "L" and rr.l) or (POINT_X[rp] == "R" and rr.r) or (rr.l + rr.r) / 2
            local y = (POINT_Y[rp] == "T" and rr.t) or (POINT_Y[rp] == "B" and rr.b) or (rr.t + rr.b) / 2
            x, y = x + (p[4] or 0), y + (p[5] or 0)
            local px, py = POINT_X[p[1]], POINT_Y[p[1]]
            if px == "L" then L = x elseif px == "R" then R = x else CX = x end
            if py == "T" then T = y elseif py == "B" then B = y else CY = y end
        end
    end
    resolving[obj] = nil
    local w, h = s.width, s.height
    if s.type == "FontString" then
        local tw, explicit = textWidth(obj)
        local size = fontSize(obj)
        if not w or w == 0 then w = (L and R) and (R - L) or tw end
        if not h or h == 0 then
            local lines = explicit
            if L and R and R > L and s.wordWrap ~= false then
                lines = math.max(explicit, math.ceil(tw / (R - L)) + explicit - 1)
            end
            h = lines * size
        end
    end
    w, h = w or 0, h or 0
    if L and R then w = R - L elseif L then R = L + w elseif R then L = R - w
    elseif CX then L, R = CX - w / 2, CX + w / 2 else return nil end
    if T and B then h = T - B elseif T then B = T - h elseif B then T = B + h
    elseif CY then T, B = CY + h / 2, CY - h / 2 else return nil end
    return { l = L, t = T, r = R, b = B }
end
H.rectOf = rectOf

function Region:GetLeft() local r = rectOf(self); return r and r.l end
function Region:GetRight() local r = rectOf(self); return r and r.r end
function Region:GetTop() local r = rectOf(self); return r and r.t end
function Region:GetBottom() local r = rectOf(self); return r and r.b end
function Region:GetCenter() local r = rectOf(self); if r then return (r.l + r.r) / 2, (r.t + r.b) / 2 end end
function Region:GetRect() local r = rectOf(self); if r then return r.l, r.b, r.r - r.l, r.t - r.b end end

-- FontString
local FontString = class("FontString", "Region")
-- Client text rules (CSimpleFontString::SetText, LanguageProcess): only
-- strings and numbers are text (anything else clears it), "|4one:many;" picks
-- the plural form for the number before it, and an empty text reads as nil.
local PLURAL = {
    frFR = function(n) return n > 1 and 1 or 0 end,
    ruRU = function(n)
        if n % 100 >= 11 and n % 100 <= 14 then return 2 end
        if n % 10 == 1 then return 0 end
        return (n % 10 >= 2 and n % 10 <= 4) and 1 or 2
    end,
}
local function pluralize(text)
    if not sfind(text, "|4", 1, true) then return text end
    local rule = PLURAL[W.locale] or function(n) return n ~= 1 and 1 or 0 end
    local number = 0
    return (sgsub(text, "()|4([^;]*);?", function(pos, forms)
        local before = smatch(ssub(text, 1, pos - 1), "(%d+)%D*$")
        number = before and tonumber(before) or number
        local list = {}
        for form in string.gmatch(forms .. ":", "([^:]*):") do list[#list + 1] = form end
        local pick = list[rule(number) + 1] or ""
        return (sgsub(pick, "^ +", ""))
    end))
end
local function clientText(text)
    if type(text) ~= "string" and type(text) ~= "number" then return nil end
    text = pluralize(tostring(text))
    if #text > 8192 then text = ssub(text, 1, 8189) end
    return text ~= "" and text or nil
end
local function hasFont(obj)
    local s = state[obj]
    return s.font ~= nil or s.fontObject ~= nil or s.ownFont
end
function FontString:SetText(text)
    if not hasFont(self) then error((state[self].name or "<unnamed>") .. ":SetText(): Font not set", 2) end
    state[self].text = clientText(text)
end
function FontString:GetText() return state[self].text end
function FontString:SetFormattedText(fmt, ...)
    if not hasFont(self) then error((state[self].name or "<unnamed>") .. ":SetFormattedText(): Font not set", 2) end
    state[self].text = clientText(wowFormat(fmt, ...))
end
function FontString:SetFont(font, size, flags) state[self].font = { font, size, flags }; return true end
function FontString:GetFont() local f = state[self].font or {}; return f[1], f[2], f[3] end
function FontString:SetFontObject(obj) state[self].fontObject = obj end
function FontString:GetFontObject() return state[self].fontObject end
function FontString:SetTextColor(r, g, b, a) state[self].color = { r, g, b, a or 1 } end
function FontString:GetTextColor() local c = state[self].color or { 1, 1, 1, 1 }; return c[1], c[2], c[3], c[4] end
function FontString:SetJustifyH(v) state[self].justifyH = v end
function FontString:SetJustifyV(v) state[self].justifyV = v end
function FontString:SetShadowColor() end
function FontString:SetShadowOffset() end
function FontString:SetNonSpaceWrap() end
function FontString:SetWordWrap(v) state[self].wordWrap = v and true or false end
function FontString:CanWordWrap() return state[self].wordWrap ~= false and 1 or nil end
function FontString:SetSpacing() end
function FontString:GetStringWidth() return (textWidth(self)) end
function FontString:GetStringHeight() return 12 end

-- Texture
local Texture = class("Texture", "Region")
function Texture:SetTexture(path, g, b, a) state[self].texture = type(path) == "number" and { path, g, b, a } or path; return true end
function Texture:GetTexture() local t = state[self].texture; return type(t) == "string" and t or nil end
function Texture:SetVertexColor(r, g, b, a) state[self].color = { r, g, b, a or 1 } end
function Texture:GetVertexColor() local c = state[self].color or { 1, 1, 1, 1 }; return c[1], c[2], c[3], c[4] end
function Texture:SetTexCoord(...) state[self].texcoord = { ... } end
function Texture:SetBlendMode(m) state[self].blend = m end
function Texture:SetDesaturated(d) state[self].desaturated = d; return true end
function Texture:SetGradient() end
function Texture:SetGradientAlpha() end

-- Frame
local Frame = class("Frame", "Region")
function Frame:SetScript(script, fn) state[self].scripts[script] = fn end
function Frame:GetScript(script) return state[self].scripts[script] end
function Frame:HasScript(script) return true end
function Frame:HookScript(script, fn)
    local s = state[self]
    if not s.scripts[script] then s.scripts[script] = fn; return end
    s.hooks[script] = s.hooks[script] or {}
    tinsert(s.hooks[script], fn)
end
function Frame:RegisterEvent(event)
    if type(event) ~= "string" and type(event) ~= "number" then
        error("Usage: " .. (state[self].name or "<unnamed>") .. ':RegisterEvent("event")', 2)
    end
    event = tostring(event)
    -- The client ignores names it has no event for (e.g. GROUP_ROSTER_UPDATE,
    -- added in 5.0): the frame never hears of them.
    if W.modernEvents[event] then
        if not report.modern_events[event] then report.modern_events[event] = where(3) end
        return
    end
    local list = W.events[event] or {}
    W.events[event] = list
    for _, f in ipairs(list) do if f == self then return end end
    tinsert(list, self)
    state[self].events[event] = true
end
function Frame:UnregisterEvent(event)
    local list = W.events[event] or {}
    for i = #list, 1, -1 do if list[i] == self then tremove(list, i) end end
    state[self].events[event] = nil
end
function Frame:UnregisterAllEvents() for event in pairs(state[self].events) do self:UnregisterEvent(event) end; state[self].allEvents = nil end
function Frame:RegisterAllEvents() state[self].allEvents = true end
function Frame:IsEventRegistered(event) return state[self].events[event] and true or false end
function Frame:CreateFontString(name, layer, inherits)
    local fs = newObject("FontString", resolveName(name, self), self)
    state[fs].layer, state[fs].fontObject = layer, inherits
    tinsert(state[self].regions, fs)
    return fs
end
function Frame:CreateTexture(name, layer)
    local tex = newObject("Texture", resolveName(name, self), self)
    state[tex].layer = layer
    tinsert(state[self].regions, tex)
    return tex
end
function Frame:GetChildren() return unpack(state[self].children) end
function Frame:GetNumChildren() return #state[self].children end
function Frame:GetRegions() return unpack(state[self].regions) end
function Frame:SetBackdrop(b) state[self].backdrop = b end
function Frame:GetBackdrop() return state[self].backdrop end
function Frame:SetBackdropColor(r, g, b, a) state[self].backdropColor = { r, g, b, a or 1 } end
function Frame:GetBackdropColor() local c = state[self].backdropColor or { 1, 1, 1, 1 }; return c[1], c[2], c[3], c[4] end
function Frame:SetBackdropBorderColor(r, g, b, a) state[self].borderColor = { r, g, b, a or 1 } end
function Frame:SetFrameStrata(v) state[self].strata = v end
function Frame:GetFrameStrata() return state[self].strata or "MEDIUM" end
function Frame:SetFrameLevel(v) state[self].level = v end
function Frame:GetFrameLevel() return state[self].level or 1 end
function Frame:SetScale(v) state[self].scale = v end
function Frame:GetScale() return state[self].scale end
function Frame:GetEffectiveScale() return state[self].scale end
function Frame:EnableMouse(v) state[self].mouse = v and true or false end
function Frame:IsMouseEnabled() return state[self].mouse or false end
function Frame:EnableMouseWheel(v) state[self].wheel = v and true or false end
function Frame:EnableKeyboard(v) state[self].keyboard = v and true or false end
function Frame:SetMovable(v) state[self].movable = v and true or false end
function Frame:IsMovable() return state[self].movable or false end
function Frame:SetResizable(v) state[self].resizable = v and true or false end
function Frame:SetMinResize(w, h) state[self].minResize = { w, h } end
function Frame:SetMaxResize(w, h) state[self].maxResize = { w, h } end
function Frame:RegisterForDrag(...) state[self].drag = { ... } end
function Frame:StartMoving() state[self].moving = true end
function Frame:StartSizing() state[self].sizing = true end
function Frame:StopMovingOrSizing() state[self].moving, state[self].sizing = nil, nil end
function Frame:SetClampedToScreen(v) state[self].clamped = v end
function Frame:SetToplevel(v) state[self].toplevel = v end
function Frame:SetUserPlaced(v) state[self].userPlaced = v end
function Frame:SetHitRectInsets() end
function Frame:Raise() end
function Frame:Lower() end
function Frame:SetID(id) state[self].id = id end
function Frame:GetID() return state[self].id or 0 end
function Frame:IsProtected() return false end
function Frame:SetAttribute(k, v) state[self].attributes[k] = v; runScript(self, "OnAttributeChanged", k, v) end
function Frame:GetAttribute(k) return state[self].attributes[k] end

-- Button / CheckButton
local Button = class("Button", "Frame")
local function buttonText(self)
    local s = state[self]
    if not s.fontString then
        s.fontString = self:CreateFontString(nil, "ARTWORK")
        state[s.fontString].ownFont = true
    end
    return s.fontString
end
-- A plain button gets its font string on the first non-empty SetText
-- (client CSimpleButton::SetText); templates bring theirs.
function Button:SetText(t)
    t = clientText(t)
    if t or state[self].fontString then state[buttonText(self)].text = t end
end
function Button:GetText() return state[self].fontString and state[self].fontString:GetText() end
function Button:SetFormattedText(fmt, ...) self:SetText(wowFormat(fmt, ...)) end
function Button:GetFontString() return state[self].fontString end
-- The width of the button's text, estimated like FontString:GetStringWidth.
function Button:GetTextWidth() return state[self].fontString and state[self].fontString:GetStringWidth() or 0 end
function Button:SetFontString(fs) state[self].fontString = fs end
function Button:SetNormalFontObject(o) state[self].normalFont = o end
function Button:SetHighlightFontObject(o) state[self].highlightFont = o end
function Button:SetDisabledFontObject(o) state[self].disabledFont = o end
function Button:SetNormalTexture(t) state[self].normalTexture = t end
function Button:SetPushedTexture(t) state[self].pushedTexture = t end
function Button:SetHighlightTexture(t) state[self].highlightTexture = t end
function Button:SetDisabledTexture(t) state[self].disabledTexture = t end
function Button:GetNormalTexture() return nil end
function Button:RegisterForClicks(...) state[self].clicks = { ... } end
function Button:Enable() state[self].enabled = true end
function Button:Disable() state[self].enabled = false end
function Button:IsEnabled() return state[self].enabled and 1 or nil end
function Button:LockHighlight() end
function Button:UnlockHighlight() end
function Button:SetButtonState() end
function Button:Click(button)
    if not state[self].enabled then return end
    runScript(self, "PreClick", button or "LeftButton", false)
    runScript(self, "OnClick", button or "LeftButton", false)
    runScript(self, "PostClick", button or "LeftButton", false)
end
local CheckButton = class("CheckButton", "Button")
function CheckButton:SetChecked(v) state[self].checked = v and true or false end
function CheckButton:GetChecked() return state[self].checked and 1 or nil end
function CheckButton:Click(button)
    if not state[self].enabled then return end
    state[self].checked = not state[self].checked
    runScript(self, "OnClick", button or "LeftButton", false)
end
function CheckButton:SetCheckedTexture() end

-- EditBox
local EditBox = class("EditBox", "Frame")
function EditBox:SetText(t)
    if type(t) ~= "string" and type(t) ~= "number" then
        error("Usage: " .. (state[self].name or "<unnamed>") .. ':SetText("text")', 2)
    end
    state[self].text = tostring(t)
    runScript(self, "OnTextChanged", false)
end
function EditBox:GetText() return state[self].text or "" end
function EditBox:Insert(t) self:SetText(self:GetText() .. tostring(t)) end
function EditBox:GetNumber() return tonumber(state[self].text) or 0 end
function EditBox:SetNumber(n) self:SetText(tostring(n)) end
function EditBox:SetAutoFocus(v) state[self].autoFocus = v end
function EditBox:SetFocus() state[self].focus = true; runScript(self, "OnEditFocusGained") end
function EditBox:ClearFocus() if state[self].focus then state[self].focus = false; runScript(self, "OnEditFocusLost") end end
function EditBox:HasFocus() return state[self].focus and 1 or nil end
function EditBox:SetMaxLetters(n) state[self].maxLetters = n end
function EditBox:GetMaxLetters() return state[self].maxLetters or 0 end
function EditBox:SetNumeric(v) state[self].numeric = v end
function EditBox:SetMultiLine(v) state[self].multiLine = v end
function EditBox:SetTextInsets() end
function EditBox:HighlightText() end
function EditBox:SetFontObject(o) state[self].fontObject = o end
function EditBox:SetFont() return true end
function EditBox:SetTextColor() end
function EditBox:SetJustifyH() end
function EditBox:SetCursorPosition(p) state[self].cursor = p end
function EditBox:AddHistoryLine() end

-- Slider / StatusBar
local Slider = class("Slider", "Frame")
function Slider:SetMinMaxValues(lo, hi) state[self].min, state[self].max = lo, hi end
function Slider:GetMinMaxValues() return state[self].min or 0, state[self].max or 0 end
function Slider:SetValue(v)
    local s = state[self]
    if s.min and v < s.min then v = s.min end
    if s.max and v > s.max then v = s.max end
    if s.value ~= v then s.value = v; runScript(self, "OnValueChanged", v) end
end
function Slider:GetValue() return state[self].value or 0 end
function Slider:SetValueStep(v) state[self].step = v end
function Slider:GetValueStep() return state[self].step or 0 end
function Slider:SetOrientation(v) state[self].orientation = v end
function Slider:SetThumbTexture() end
function Slider:Enable() state[self].enabled = true end
function Slider:Disable() state[self].enabled = false end
local StatusBar = class("StatusBar", "Frame")
StatusBar.SetMinMaxValues, StatusBar.GetMinMaxValues, StatusBar.GetValue = Slider.SetMinMaxValues, Slider.GetMinMaxValues, Slider.GetValue
function StatusBar:SetValue(v) state[self].value = v; runScript(self, "OnValueChanged", v) end
function StatusBar:SetStatusBarTexture(t) state[self].barTexture = t end
function StatusBar:GetStatusBarTexture() return nil end
function StatusBar:SetStatusBarColor(r, g, b, a) state[self].barColor = { r, g, b, a } end
function StatusBar:SetOrientation(v) state[self].orientation = v end

-- ScrollFrame
local ScrollFrame = class("ScrollFrame", "Frame")
function ScrollFrame:SetScrollChild(c) state[self].scrollChild = c end
function ScrollFrame:GetScrollChild() return state[self].scrollChild end
function ScrollFrame:SetVerticalScroll(v) state[self].vscroll = v; runScript(self, "OnVerticalScroll", v) end
function ScrollFrame:GetVerticalScroll() return state[self].vscroll or 0 end
function ScrollFrame:SetHorizontalScroll(v) state[self].hscroll = v end
function ScrollFrame:GetVerticalScrollRange() return 0 end
function ScrollFrame:UpdateScrollChildRect() end

-- MessageFrame / ScrollingMessageFrame / GameTooltip / misc
local MessageFrame = class("MessageFrame", "Frame")
function MessageFrame:AddMessage(text, r, g, b)
    local s = state[self]
    s.messages = s.messages or {}
    tinsert(s.messages, tostring(text))
    if s.isChat then tinsert(W.chat, tostring(text)) end
end
function MessageFrame:Clear() state[self].messages = {} end
function MessageFrame:SetFading() end
function MessageFrame:SetTimeVisible() end
function MessageFrame:SetMaxLines() end
function MessageFrame:SetFontObject() end
function MessageFrame:SetJustifyH() end
function MessageFrame:SetInsertMode() end
local ScrollingMessageFrame = class("ScrollingMessageFrame", "MessageFrame")
function ScrollingMessageFrame:ScrollToBottom() end
local GameTooltip = class("GameTooltip", "Frame")
-- A named tooltip exposes its lines as <name>TextLeft<i> font strings, the way
-- addons scan tooltips (e.g. for ITEM_BIND_ON_EQUIP).
local function syncTooltipLines(self)
    local s = state[self]
    if not s.name then return end
    local lines = s.lines or {}
    for i = 1, math.max(#lines, s.synced or 0) do
        local key = s.name .. "TextLeft" .. i
        local fs = W.env[key]
        if not fs then fs = newObject("FontString", key, self); state[fs].ownFont = true end
        state[fs].text = lines[i]
    end
    s.synced = #lines
end
function GameTooltip:SetOwner(owner, anchor) state[self].owner, state[self].lines = owner, {}; syncTooltipLines(self) end
function GameTooltip:GetOwner() return state[self].owner end
function GameTooltip:ClearLines() state[self].lines = {}; syncTooltipLines(self) end
function GameTooltip:SetText(t) state[self].lines = { tostring(t) }; syncTooltipLines(self) end
function GameTooltip:AddLine(t)
    state[self].lines = state[self].lines or {}
    tinsert(state[self].lines, tostring(t))
    syncTooltipLines(self)
end
function GameTooltip:AddDoubleLine(l, r) self:AddLine(tostring(l) .. "  " .. tostring(r)) end
function GameTooltip:NumLines() return #(state[self].lines or {}) end
-- Line 1 is the link; forge.item(id, { tooltip = { ITEM_BIND_ON_EQUIP, ... } })
-- adds the item's further tooltip lines.
function GameTooltip:SetHyperlink(link)
    self:SetText(link)
    local def = W.items[tonumber(string.match(tostring(link), "item:(%d+)") or "")]
    for _, line in ipairs(def and def.tooltip or {}) do self:AddLine(W.env[line] or line) end
end
function GameTooltip:IsOwned(f) return state[self].owner == f end
class("Cooldown", "Frame").SetCooldown = function(self, start, dur) state[self].cooldown = { start, dur } end
class("Model", "Frame")
class("PlayerModel", "Model")
class("ColorSelect", "Frame")
class("SimpleHTML", "Frame")
class("Minimap", "Frame")

local FontObject = class("Font")
function FontObject:SetFont(...) state[self].font = { ... } end
function FontObject:GetFont() local f = state[self].font or { "Fonts\\FRIZQT__.TTF", 12 }; return f[1], f[2], f[3] end
function FontObject:SetTextColor(...) state[self].color = { ... } end
function FontObject:GetTextColor() local c = state[self].color or { 1, 1, 1, 1 }; return c[1], c[2], c[3], c[4] end
function FontObject:CopyFontObject(o) if state[o] then state[self].font = state[o].font end end
function FontObject:SetJustifyH() end
function FontObject:SetShadowColor() end
function FontObject:SetShadowOffset() end
function FontObject:GetName() return state[self].name end

local FRAME_TYPES = { Frame = 1, Button = 1, CheckButton = 1, EditBox = 1, Slider = 1, StatusBar = 1,
    ScrollFrame = 1, MessageFrame = 1, ScrollingMessageFrame = 1, GameTooltip = 1, Cooldown = 1,
    Model = 1, PlayerModel = 1, ColorSelect = 1, SimpleHTML = 1, Minimap = 1 }
local KNOWN_TEMPLATES = { UIPanelButtonTemplate = 1, UIPanelButtonTemplate2 = 1, InputBoxTemplate = 1,
    UIPanelScrollFrameTemplate = 1, UIPanelCloseButton = 1, GameTooltipTemplate = 1,
    OptionsCheckButtonTemplate = 1, UICheckButtonTemplate = 1, OptionsSliderTemplate = 1,
    UIDropDownMenuTemplate = 1, SecureActionButtonTemplate = 1, SecureHandlerStateTemplate = 1,
    ActionButtonTemplate = 1, ChatConfigCheckButtonTemplate = 1, FauxScrollFrameTemplate = 1,
    UIPanelDialogTemplate = 1, TranslucentFrameTemplate = 1, ItemButtonTemplate = 1,
    TabButtonTemplate = 1, CharacterFrameTabButtonTemplate = 1, OptionsFrameTabButtonTemplate = 1 }

local function CreateFrame(kind, name, parent, template)
    if not FRAME_TYPES[kind] then error("CreateFrame: Unknown frame type '" .. tostring(kind) .. "'", 2) end
    if type(parent) == "string" then parent = W.env[parent] end
    local frame = newObject(kind, resolveName(name, parent), parent)
    state[frame].template = template
    if type(template) == "string" then
        for t in string.gmatch(template, "[^,%s]+") do
            if not KNOWN_TEMPLATES[t] then report.unknown_templates[t] = where(3) end
            local fname = state[frame].name
            if t == "UIPanelScrollFrameTemplate" and fname then
                local bar = newObject("Slider", fname .. "ScrollBar", frame)
                state[frame].scrollBar = bar
            elseif (t == "OptionsCheckButtonTemplate" or t == "UICheckButtonTemplate") and fname then
                state[newObject("FontString", fname .. "Text", frame)].ownFont = true
            elseif t == "OptionsSliderTemplate" and fname then
                for _, part in ipairs({ "Text", "Low", "High" }) do
                    state[newObject("FontString", fname .. part, frame)].ownFont = true
                end
            end
        end
    end
    if (kind == "Button" or kind == "CheckButton") and template then buttonText(frame) end
    return frame
end

---------------------------------------------------------------- game state & API
local function defaultUnits()
    return {
        player = { name = "Tester", class = "Warrior", classToken = "WARRIOR", level = 80, health = 30000,
                   maxHealth = 30000, power = 100, maxPower = 100, race = "Human", raceToken = "Human",
                   guid = "0x0000000000000001", isPlayer = true, faction = "Alliance", sex = 2, connected = true },
    }
end

local function unitData(unit)
    if type(unit) ~= "string" then return nil end
    unit = slower(unit)
    local u = W.units[unit]
    if u then return u end
    for _, data in pairs(W.units) do
        if data.name and slower(data.name) == unit then return data end
    end
    return nil
end

local function emit(text) tinsert(W.chat, tostring(text)) end

-- Client FrameScript_SignalEvent: listeners in registration order; a frame
-- registered during the dispatch waits for the next signal, a frame
-- unregistered during it is skipped for the rest of this one.
local function fire(event, ...)
    local seen, list = {}, {}
    for i, frame in ipairs(W.events[event] or {}) do list[i] = frame end
    for _, frame in ipairs(list) do
        seen[frame] = true
        if state[frame].events[event] then runScript(frame, "OnEvent", event, ...) end
    end
    for _, frame in ipairs(W.objects) do
        if not seen[frame] and state[frame].allEvents then runScript(frame, "OnEvent", event, ...) end
    end
end

local function slashDispatch(text)
    local command, rest = smatch(text, "^(/%S+)%s*(.-)$")
    if not command then error("forge.slash expects '/command args'", 2) end
    command = slower(command)
    local list = W.env.SlashCmdList or {}
    for key, handler in pairs(list) do
        local i = 1
        while true do
            local alias = rawget(W.env, "SLASH_" .. key .. i)
            if not alias then break end
            if slower(alias) == command then
                local ok, err = budgeted(handler, rest, nil)
                if not ok then recordError("slash " .. command .. ": " .. tostring(err)) end
                return true
            end
            i = i + 1
        end
    end
    error("No addon registered slash command " .. command, 2)
end

-- Protected actions (client CGGameUI::CanPerformAction and its callers). Addon
-- code is always tainted, so: "hardware" functions need a real click or key
-- press in progress (a button's OnClick from the mouse or a key binding, an
-- edit box's OnEnterPressed from the Enter key), "combat" ones are refused in
-- combat, "forbidden" ones never work from an addon. A refused call does
-- nothing and fires ADDON_ACTION_BLOCKED / ADDON_ACTION_FORBIDDEN with the
-- addon name and "Function()".
local PROTECTED = {}   -- name -> kind, so forge.stub keeps the guard
local function protected(name, kind, fn)
    PROTECTED[name] = kind
    return function(...)
        local refused = kind == "forbidden" or (kind == "hardware" and not W.hardware)
            or (kind == "combat" and W.combat)
        if refused then
            tinsert(W.blocked, name)
            fire(kind == "forbidden" and "ADDON_ACTION_FORBIDDEN" or "ADDON_ACTION_BLOCKED", W.addonName, name .. "()")
            return
        end
        return fn(...)
    end
end
local function recorder(name)
    return function(...) tinsert(W.protectedCalls, { name = name, args = { ... } }) end
end

local function api(env)
    local E = env
    E.CreateFrame = CreateFrame
    E.CreateFont = function(name)
        local f = newObject("Font", name)
        return f
    end
    E.GetTime = function() return W.time end
    E.time = function(t) if t then return os_time(t) end return W.epoch + floor(W.time) end
    E.date = function(fmt, t) return os_date(fmt, t or (W.epoch + floor(W.time))) end
    E.difftime = function(a, b) return a - b end
    E.debugprofilestop = function() return W.time * 1000 end
    E.debugprofilestart = function() end
    E.debugstack = function() return traceback("", 2) end
    E.GetFramerate = function() return 60 end
    E.GetLocale = function() return W.locale end
    E.GetRealmName = function() return W.realm end
    E.GetBuildInfo = function() return "3.3.5", "12340", "Jun 24 2010", 30300 end
    E.GetCVar = function(k) return W.cvars[k] end
    E.SetCVar = function(k, v) W.cvars[k] = v end
    E.GetAddOnMetadata = function(addon, field) if addon == W.addonName then return W.metadata[field] end end
    E.IsAddOnLoaded = function(addon) return addon == W.addonName and 1 or nil end
    E.GetNumAddOns = function() return 1 end
    E.GetScreenWidth = function() return 1280 end
    E.GetScreenHeight = function() return 720 end
    E.GetCursorPosition = function() return 640, 360 end
    E.IsShiftKeyDown = function() return W.keys.shift end
    E.IsControlKeyDown = function() return W.keys.ctrl end
    E.IsAltKeyDown = function() return W.keys.alt end
    E.IsModifiedClick = function() return nil end
    E.InCombatLockdown = function() return W.combat and 1 or nil end
    E.PlaySound = function(name) tinsert(W.sounds, tostring(name)) end
    E.PlaySoundFile = function(name) tinsert(W.sounds, tostring(name)) end
    E.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        emit(tconcat(parts, " "))
    end
    E.SendChatMessage = function(msg, chatType, lang, target)
        tinsert(W.sent, { message = tostring(msg), chatType = chatType or "SAY", target = target })
    end
    -- Client Script_SendAddonMessage: PARTY by default; RAID outside a raid
    -- goes to the party; PARTY without a party is dropped silently; other chat
    -- types are an error. The receiver splits "prefix<TAB>message" at the
    -- first tab, so a tab in the prefix moves the rest into the message.
    local ADDON_TYPES = { PARTY = 1, RAID = 1, GUILD = 1, BATTLEGROUND = 1, WHISPER = 1 }
    E.SendAddonMessage = function(prefix, msg, chatType, target)
        prefix = (type(prefix) == "string" or type(prefix) == "number") and tostring(prefix) or ""
        msg = (type(msg) == "string" or type(msg) == "number") and tostring(msg) or ""
        if prefix == "" and msg == "" then
            error('Usage: SendAddonMessage("prefix", "message" [,"type"] [,"target"])', 2)
        end
        local kind = "PARTY"
        if type(chatType) == "string" or type(chatType) == "number" then
            kind = supper(tostring(chatType))
            if not ADDON_TYPES[kind] then error("Unknown addon chat type", 2) end
        end
        if kind == "RAID" and #W.raid == 0 then kind = "PARTY" end
        if kind == "PARTY" and W.partyCount == 0 and #W.raid == 0 then return end
        if kind == "WHISPER" and (type(target) ~= "string" or target == "") then
            error("SendAddonMessage(): Whisper message missing target player!", 2)
        end
        local line = ssub(prefix .. "	" .. msg, 1, 2999)
        local p, m = smatch(line, "^([^	]*)	(.*)$")
        tinsert(W.addonMessages, { prefix = p, message = m, chatType = kind, target = target })
    end
    E.ChatFrame_AddMessageEventFilter = function(event, fn) W.chatFilters[event] = W.chatFilters[event] or {}; tinsert(W.chatFilters[event], fn) end
    E.ChatFrame_RemoveMessageEventFilter = function() end
    E.RandomRoll = function(lo, hi)
        lo, hi = tonumber(lo) or 1, tonumber(hi) or 100
        local value = W.nextRolls[1] and tremove(W.nextRolls, 1) or lo
        fire("CHAT_MSG_SYSTEM", wowFormat(E.RANDOM_ROLL_RESULT, E.UnitName("player"), value, lo, hi))
    end
    -- Units
    E.UnitExists = function(u) return unitData(u) and 1 or nil end
    E.UnitName = function(u) local d = unitData(u); if d then return d.name, d.realm end end
    E.UnitClass = function(u) local d = unitData(u); if d then return d.class, d.classToken end end
    E.UnitRace = function(u) local d = unitData(u); if d then return d.race, d.raceToken end end
    E.UnitLevel = function(u) local d = unitData(u); return d and d.level or 0 end
    E.UnitHealth = function(u) local d = unitData(u); return d and d.health or 0 end
    E.UnitHealthMax = function(u) local d = unitData(u); return d and d.maxHealth or 0 end
    E.UnitPower = function(u) local d = unitData(u); return d and d.power or 0 end
    E.UnitPowerMax = function(u) local d = unitData(u); return d and d.maxPower or 0 end
    E.UnitMana, E.UnitManaMax = E.UnitPower, E.UnitPowerMax
    E.UnitGUID = function(u) local d = unitData(u); return d and d.guid end
    E.UnitIsPlayer = function(u) local d = unitData(u); return d and d.isPlayer and 1 or nil end
    E.UnitIsUnit = function(a, b) local x, y = unitData(a), unitData(b); return x and x == y and 1 or nil end
    E.UnitIsDead = function(u) local d = unitData(u); return d and d.dead and 1 or nil end
    E.UnitIsDeadOrGhost = E.UnitIsDead
    E.UnitIsConnected = function(u) local d = unitData(u); return d and d.connected ~= false and 1 or nil end
    E.UnitAffectingCombat = function(u) return slower(u or "") == "player" and W.combat and 1 or nil end
    E.UnitFactionGroup = function(u) local d = unitData(u); if d then return d.faction, d.faction end end
    E.UnitSex = function(u) local d = unitData(u); return d and d.sex or 1 end
    E.UnitInParty = function(u) local d = unitData(u); return d and (d == W.units.player or d.party) and 1 or nil end
    E.UnitInRaid = function(u) local d = unitData(u); return d and d.raidIndex or nil end
    E.UnitIsFriend = function() return 1 end
    E.UnitIsEnemy = function() return nil end
    E.UnitCanAttack = function() return nil end
    E.UnitIsAFK = function() return nil end
    E.UnitGroupRolesAssigned = function() return nil, nil, nil end
    -- Groups
    E.GetNumPartyMembers = function() return W.partyCount end
    E.GetNumRaidMembers = function() return #W.raid end
    E.GetRaidRosterInfo = function(i)
        local m = W.raid[i]
        if m then return m.name, m.rank or 0, m.subgroup or 1, m.level or 80, m.class or "Warrior",
            m.classToken or "WARRIOR", m.zone or "Dalaran", m.online ~= false and 1 or nil, m.dead and 1 or nil,
            m.role, m.isML and 1 or nil end
    end
    E.IsPartyLeader = function() return W.leader and 1 or nil end
    E.IsRaidLeader = function() return W.leader and #W.raid > 0 and 1 or nil end
    E.IsRaidOfficer = function() return W.leader and #W.raid > 0 and 1 or nil end
    E.GetPartyLeaderIndex = function() return 0 end
    -- The raid index of the master looter is nil outside a raid, as in the client.
    E.GetLootMethod = function()
        return W.lootMethod.method, W.lootMethod.party, #W.raid > 0 and W.lootMethod.raid or nil
    end
    E.GetLootThreshold = function() return W.lootMethod.threshold or 2 end
    E.GetMasterLootCandidate = function(i) local c = W.lootCandidates[i]; return c end
    -- The server answers a master-loot handout later: the slot empties and the
    -- group sees a CHAT_MSG_LOOT line on the next frame (see forge.advance).
    E.GiveMasterLoot = function(slot, index)
        local candidate = W.lootCandidates[index]
        tinsert(W.awards, { slot = slot, candidate = candidate })
        local l = W.lootOpen and W.loot[slot]
        if not candidate or not l or not l.link then return end
        local link = l.link
        tinsert(W.pending, function()
            if W.loot[slot] == l then W.loot[slot] = {} end
            if candidate == E.UnitName("player") then
                fire("CHAT_MSG_LOOT", wowFormat(E.LOOT_ITEM_SELF, link))
            else
                fire("CHAT_MSG_LOOT", wowFormat(E.LOOT_ITEM, candidate, link))
            end
        end)
    end
    E.GetTradePlayerItemLink = function(slot) return W.trade and W.trade.items[slot] end
    E.AcceptTrade = protected("AcceptTrade", "hardware", function() if W.trade then W.trade.playerAccepted = true end end)
    E.CancelTrade = function() end
    -- Hardware-event functions; when allowed they are recorded for specs
    -- (forge.protectedCalls()) unless a spec stubs them.
    for _, name in ipairs({ "CalendarAddEvent", "CalendarUpdateEvent", "CancelTradeAccept", "PlaceAuctionBid",
        "CancelAuction", "AcceptProposal", "AcceptBattlefieldPort" }) do
        E[name] = protected(name, "hardware", recorder(name))
    end
    for _, name in ipairs({ "SetRaidSubgroup", "SwapRaidSubgroup", "CreateMacro", "EditMacro", "DeleteMacro",
        "SetBinding", "SetBindingClick", "SetBindingSpell", "SetBindingItem", "SetBindingMacro",
        "SetOverrideBinding", "SetOverrideBindingClick", "ClearOverrideBindings", "PickupAction",
        "PlaceAction", "PickupSpell", "PickupMacro", "PickupPetAction", "ChangeActionBarPage",
        "AutoEquipCursorItem" }) do
        E[name] = protected(name, "combat", recorder(name))
    end
    for _, name in ipairs({ "TargetUnit", "RunMacro", "StopMacro", "SpellStopCasting", "SpellTargetUnit", "MoveForwardStart", "JumpOrAscendStart", "ToggleAutoRun" }) do
        E[name] = protected(name, "forbidden", recorder(name))
    end
    -- /reload from addon code needs a hardware event too (CGGameUI::Reload);
    -- the client reloads at its next idle, here on the next forge.advance step.
    E.ReloadUI = protected("ReloadUI", "hardware", function() tinsert(W.pending, function() H.forge.reload() end) end)
    -- Loot and items
    E.GetNumLootItems = function() return W.lootOpen and #W.loot or 0 end
    E.GetLootSlotLink = function(slot) local l = W.lootOpen and W.loot[slot]; return l and l.link end
    E.GetLootSlotInfo = function(slot)
        local l = W.lootOpen and W.loot[slot]
        if l then return l.texture or "Interface\\Icons\\INV_Misc_QuestionMark", l.name, l.quantity or 1, l.quality or 4, l.locked end
    end
    E.LootSlotIsItem = function(slot) local l = W.lootOpen and W.loot[slot]; return l and l.link and 1 or nil end
    E.LootSlotIsCoin = function(slot) local l = W.lootOpen and W.loot[slot]; return l and l.coin and 1 or nil end
    E.LootSlot = function(slot) tinsert(W.looted, slot) end
    E.CloseLoot = function() if W.lootOpen then W.lootOpen = false; E.LootFrame:Hide(); fire("LOOT_CLOSED") end end
    E.GetItemInfo = function(item)
        local key = item
        if type(item) == "string" then key = tonumber(smatch(item, "item:(%d+)")) or item end
        local i = W.items[key]
        if not i and type(key) == "string" then
            for _, data in pairs(W.items) do if data.name == key then i = data end end
        end
        if i then return i.name, i.link, i.quality or 1, i.itemLevel or 1, i.minLevel or 1, i.type or "Miscellaneous",
            i.subType or "Junk", i.stackCount or 1, i.equipLoc or "", i.texture or "Interface\\Icons\\INV_Misc_QuestionMark", i.sellPrice or 0 end
    end
    E.GetItemQualityColor = function(q)
        local c = E.ITEM_QUALITY_COLORS[q] or E.ITEM_QUALITY_COLORS[1]
        return c.r, c.g, c.b, c.hex
    end
    E.GetGameTime = function()
        local minutes = floor((W.gameMinutes + W.time / 60) % 1440)
        return floor(minutes / 60), minutes % 60
    end
    E.GetPlayerMapPosition = function(u) if slower(u or "") == "player" then return W.mapX, W.mapY end return 0, 0 end
    E.SetMapToCurrentZone = function() end
    E.GetNetStats = function() return 0, 0, 50 end
    E.GetNumQuestLogEntries = function() return 0, 0 end
    E.IsResting = function() return nil end
    E.UnitXP = function() return 0 end
    E.UnitXPMax = function() return 1 end
    E.GetXPExhaustion = function() return nil end
    E.GetMoney = function() return W.money end
    E.GetZoneText = function() return W.zone end
    E.GetRealZoneText = function() return W.zone end
    E.GetSubZoneText = function() return "" end
    E.GetMinimapZoneText = function() return W.zone end
    E.IsInInstance = function() return nil, "none" end
    E.IsInGuild = function() return nil end
    E.GetGuildInfo = function() return nil end
    -- Secure/hooks/misc FrameXML helpers
    E.hooksecurefunc = function(a, b, c)
        local tbl, name, hook = a, b, c
        if type(a) == "string" then tbl, name, hook = E, a, b end
        local original = tbl[name]
        if type(original) ~= "function" then error("hooksecurefunc(): " .. tostring(name) .. " is not a function", 2) end
        tbl[name] = function(...) local r = { original(...) }; hook(...); return unpack(r) end
    end
    E.securecall = function(fn, ...) if type(fn) == "string" then fn = E[fn] end return fn(...) end
    E.issecurevariable = function() return 1, nil end
    E.geterrorhandler = function() return W.errorHandler end
    E.seterrorhandler = function(fn) W.errorHandler = fn end
    E.StaticPopup_Show = function(which, a, b, data) tinsert(W.popups, { which = which, text1 = a, text2 = b, data = data }) end
    E.StaticPopup_Hide = function() end
    E.InterfaceOptions_AddCategory = function(panel) tinsert(W.optionsPanels, panel) end
    E.InterfaceOptionsFrame_OpenToCategory = function() end
    E.ToggleFrame = function(f) if f:IsShown() then f:Hide() else f:Show() end end
    E.ShowUIPanel = function(f) if f then f:Show() end end
    E.HideUIPanel = function(f) if f then f:Hide() end end
    E.FauxScrollFrame_Update = function() end
    E.FauxScrollFrame_GetOffset = function() return 0 end
    E.FauxScrollFrame_OnVerticalScroll = function() end
    E.UIDropDownMenu_Initialize = function() end
    E.UIDropDownMenu_SetWidth = function() end
    E.UIDropDownMenu_SetText = function() end
    E.UIDropDownMenu_CreateInfo = function() return {} end
    E.UIDropDownMenu_AddButton = function() end
    E.UIDropDownMenu_SetSelectedValue = function() end
    E.EasyMenu = function() end
    -- Lua 5.1 + WoW library extras
    E.strsplit = function(sep, text, limit)
        local out, pos, count = {}, 1, 0
        if text == nil then return nil end
        while true do
            count = count + 1
            local s, e = sfind(text, "[" .. sgsub(sep, "[%]%^%-%%]", "%%%0") .. "]", pos)
            if not s or (limit and count >= limit) then tinsert(out, ssub(text, pos)); break end
            tinsert(out, ssub(text, pos, s - 1))
            pos = e + 1
        end
        return unpack(out)
    end
    E.strjoin = function(sep, ...) local p = {}; for i = 1, select("#", ...) do p[i] = tostring((select(i, ...))) end; return tconcat(p, sep) end
    E.strtrim = function(s, chars)
        chars = chars and ("[" .. sgsub(chars, "[%]%^%-%%]", "%%%0") .. "]") or "%s"
        return (sgsub(sgsub(s, "^" .. chars .. "+", ""), chars .. "+$", ""))
    end
    E.strconcat = function(...) return tconcat({ ... }) end
    E.tostringall = function(...) local r = {}; for i = 1, select("#", ...) do r[i] = tostring((select(i, ...))) end; return unpack(r) end
    E.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    string.split, string.trim, string.join = function(text, sep, limit) return E.strsplit(sep, text, limit) end, E.strtrim, E.strjoin
    table.wipe = E.wipe
    E.strbyte, E.strchar, E.strfind, E.strformat, E.strlen, E.strlower = string.byte, string.char, sfind, wowFormat, string.len, slower
    E.strmatch, E.strrep, E.strrev, E.strsub, E.strupper, E.gmatch, E.gsub, E.format = smatch, srep, string.reverse, ssub, supper, string.gmatch, sgsub, wowFormat
    E.tinsert, E.tremove, E.sort, E.getn, E.foreach, E.foreachi = tinsert, tremove, tsort, table.getn, table.foreach, table.foreachi
    E.abs, E.ceil, E.floor, E.max, E.min, E.mod, E.sqrt, E.random = math.abs, math.ceil, floor, math.max, math.min, math.fmod, math.sqrt, math.random
    E.exp, E.log, E.log10, E.frexp, E.ldexp = math.exp, math.log, math.log10, math.frexp, math.ldexp
    E.cos = function(d) return math.cos(math.rad(d)) end
    E.sin = function(d) return math.sin(math.rad(d)) end
    E.tan = function(d) return math.tan(math.rad(d)) end
    E.deg, E.rad, E.PI = math.deg, math.rad, math.pi
    local function tobit(x) x = floor(tonumber(x) or 0) % 4294967296; return x end
    local function bitop(a, b, f)
        a, b = tobit(a), tobit(b)
        local r, p = 0, 1
        for _ = 1, 32 do
            if f(a % 2, b % 2) then r = r + p end
            a, b, p = floor(a / 2), floor(b / 2), p * 2
        end
        return r
    end
    E.bit = {
        band = function(a, b) return bitop(a, b, function(x, y) return x == 1 and y == 1 end) end,
        bor = function(a, b) return bitop(a, b, function(x, y) return x == 1 or y == 1 end) end,
        bxor = function(a, b) return bitop(a, b, function(x, y) return x ~= y end) end,
        bnot = function(a) return 4294967295 - tobit(a) end,
        lshift = function(a, n) return tobit(tobit(a) * 2 ^ n) end,
        rshift = function(a, n) return floor(tobit(a) / 2 ^ n) end,
        mod = math.fmod,
    }
    E.loadstring = function(src, name)
        if type(src) == "string" and ssub(src, 1, 1) == "\27" then return nil, "binary chunks are not allowed" end
        local fn, err = real_loadstring(src, name)
        if fn then real_setfenv(fn, E) end
        return fn, err
    end
    -- Constants and GlobalStrings an addon commonly reads.
    E.STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
    E.UNIT_NAME_FONT = "Fonts\\FRIZQT__.TTF"
    E.DAMAGE_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
    E.RANDOM_ROLL_RESULT = W.strings.RANDOM_ROLL_RESULT
    for k, v in pairs(W.strings) do E[k] = v end
    E.RAID_CLASS_COLORS = {}
    for token, rgb in pairs({ WARRIOR = { 0.78, 0.61, 0.43 }, PALADIN = { 0.96, 0.55, 0.73 }, HUNTER = { 0.67, 0.83, 0.45 },
        ROGUE = { 1, 0.96, 0.41 }, PRIEST = { 1, 1, 1 }, DEATHKNIGHT = { 0.77, 0.12, 0.23 }, SHAMAN = { 0, 0.44, 0.87 },
        MAGE = { 0.41, 0.8, 0.94 }, WARLOCK = { 0.58, 0.51, 0.79 }, DRUID = { 1, 0.49, 0.04 } }) do
        E.RAID_CLASS_COLORS[token] = { r = rgb[1], g = rgb[2], b = rgb[3] }
    end
    E.ITEM_QUALITY_COLORS = {}
    for q, rgb in pairs({ [0] = { 0.62, 0.62, 0.62, "ff9d9d9d" }, [1] = { 1, 1, 1, "ffffffff" }, [2] = { 0.12, 1, 0, "ff1eff00" },
        [3] = { 0, 0.44, 0.87, "ff0070dd" }, [4] = { 0.64, 0.21, 0.93, "ffa335ee" }, [5] = { 1, 0.5, 0, "ffff8000" },
        [6] = { 0.9, 0.8, 0.5, "ffe6cc80" }, [7] = { 0.9, 0.8, 0.5, "ffe6cc80" } }) do
        E.ITEM_QUALITY_COLORS[q] = { r = rgb[1], g = rgb[2], b = rgb[3], hex = "|c" .. rgb[4] }
    end
    E.MAX_PARTY_MEMBERS, E.MAX_RAID_MEMBERS, E.NUM_CHAT_WINDOWS = 4, 40, 10
    E.SlashCmdList = {}
    E.StaticPopupDialogs = {}
    E.UISpecialFrames = {}
    E.Lib = nil
end

local FONT_PATTERNS = { "^GameFont", "^ChatFont", "^NumberFont", "^SystemFont", "^QuestFont", "^DialogButton",
    "^SubZoneText", "^ZoneText", "^Tooltip", "^Game.*Font", "^FriendsFont", "^InvoiceFont", "^MailFont", "^SpellFont" }

local function newWorld(config, saved)
    W = { objects = {}, events = {}, chat = {}, sent = {}, addonMessages = {}, sounds = {}, popups = {},
          optionsPanels = {}, chatFilters = {}, awards = {}, looted = {}, loot = {}, lootOpen = false,
          lootCandidates = {}, lootMethod = { method = "group" }, raid = {}, partyCount = 0, leader = false,
          items = {}, nextRolls = {}, pending = {}, time = 0, epoch = 1281052800, combat = false, keys = {},
          money = 0, zone = "Dalaran", realm = "AzerothCore", locale = config.locale or "enUS",
          gameMinutes = 12 * 60, mapX = 0.5, mapY = 0.5, hardware = false, blocked = {}, protectedCalls = {},
          cvars = {}, units = defaultUnits(), addonName = config.addonName, metadata = config.metadata or {},
          strings = { RANDOM_ROLL_RESULT = "%s rolls %d (%d-%d)", OKAY = "Okay", CANCEL = "Cancel", YES = "Yes",
                      NO = "No", ACCEPT = "Accept", DECLINE = "Decline", CLOSE = "Close", NONE = "None",
                      LOOT_ITEM = "%s receives loot: %s.", LOOT_ITEM_SELF = "You receive loot: %s.",
                      ERR_TRADE_COMPLETE = "Trade complete.", ERR_TRADE_CANCELLED = "Trade cancelled.",
                      ITEM_BIND_ON_EQUIP = "Binds when equipped", ITEM_BIND_ON_PICKUP = "Binds when picked up",
                      ITEM_SOULBOUND = "Soulbound" } }
    local E = {}
    W.env = E
    E._G = E
    -- Expose pure Lua builtins.
    for _, name in ipairs({ "assert", "collectgarbage", "error", "getfenv", "getmetatable", "ipairs", "next",
        "pairs", "pcall", "rawequal", "rawget", "rawset", "select", "setfenv", "setmetatable", "tonumber",
        "tostring", "type", "unpack", "xpcall", "gcinfo", "newproxy", "coroutine", "math", "string", "table" }) do
        E[name] = _G[name]
    end
    E._VERSION = _VERSION
    E.load = nil
    for k, v in pairs(config.strings or {}) do W.strings[k] = v end
    api(E)
    E.UIParent = newObject("Frame", "UIParent")
    state[E.UIParent].width, state[E.UIParent].height = 1280, 720
    E.WorldFrame = newObject("Frame", "WorldFrame")
    E.Minimap = newObject("Minimap", "Minimap", E.UIParent)
    E.ChatFrame1 = newObject("ScrollingMessageFrame", "ChatFrame1", E.UIParent)
    state[E.ChatFrame1].isChat = true
    E.DEFAULT_CHAT_FRAME, E.SELECTED_CHAT_FRAME = E.ChatFrame1, E.ChatFrame1
    E.ChatFrame1EditBox = newObject("EditBox", "ChatFrame1EditBox", E.ChatFrame1)
    E.UIErrorsFrame = newObject("MessageFrame", "UIErrorsFrame", E.UIParent)
    E.GameTooltip = newObject("GameTooltip", "GameTooltip", E.UIParent)
    state[E.GameTooltip].shown = false
    E.ItemRefTooltip = newObject("GameTooltip", "ItemRefTooltip", E.UIParent)
    state[E.ItemRefTooltip].shown = false
    E.LootFrame = newObject("Frame", "LootFrame", E.UIParent)
    state[E.LootFrame].shown = false
    E.InterfaceOptionsFramePanelContainer = newObject("Frame", "InterfaceOptionsFramePanelContainer", E.UIParent)
    E.StaticPopup1 = newObject("Frame", "StaticPopup1", E.UIParent)
    state[E.StaticPopup1].shown = false
    -- Missing globals: record reads from addon/spec code, lazily provide font objects.
    setmetatable(E, { __index = function(t, key)
        if type(key) == "string" then
            for _, p in ipairs(FONT_PATTERNS) do
                if sfind(key, p) then local f = newObject("Font", key); rawset(t, key, f); return f end
            end
            if not report.nil_globals[key] then report.nil_globals[key] = where(3) end
        end
        return nil
    end })
    W.knownMethods = config.methods
    W.modernEvents = config.modernEvents or {}
    W.savedNames = config.savedVariables or {}
    W.saved = saved or {}
    return E
end

---------------------------------------------------------------- spec API (the `forge` table)
local forge = {}
H.forge = forge

local function asFrame(f)
    if type(f) == "string" then
        local obj = rawget(W.env, f)
        if not obj then error("No frame named " .. f, 3) end
        return obj
    end
    if not state[f] then error("Expected a frame", 3) end
    return f
end

function forge.fire(event, ...) fire(event, ...) end
-- forge.slash(text[, { hardware = true }]): hardware = typed into chat by a
-- person (the chat box's Enter is a hardware event); without it the command
-- runs like a plan `slash` step (SDK Lua, no hardware event).
local function withHardware(on, fn, ...)
    local before = W.hardware
    W.hardware = on and true or false
    local ok, err = pcall(fn, ...)
    W.hardware = before
    if not ok then error(err, 0) end
end
function forge.slash(text, opts) withHardware(opts and opts.hardware, slashDispatch, text) end
function forge.advance(seconds, step)
    step = step or 0.05
    local remaining = seconds
    while remaining > 1e-9 do
        local dt = remaining < step and remaining or step
        W.time = W.time + dt
        remaining = remaining - dt
        local pending = W.pending
        W.pending = {}
        for _, fn in ipairs(pending) do fn() end
        -- One pass over the frames visible when the frame starts (client
        -- CFrameStrataNode::OnLayerUpdate): a frame shown by another's
        -- OnUpdate waits for the next frame, a hidden one is skipped.
        local visible = {}
        for _, obj in ipairs(W.objects) do
            if state[obj].scripts.OnUpdate and obj:IsVisible() then visible[#visible + 1] = obj end
        end
        for _, obj in ipairs(visible) do
            if state[obj].scripts.OnUpdate and obj:IsVisible() then runScript(obj, "OnUpdate", dt) end
        end
    end
end
function forge.click(frame, button)
    local f = asFrame(frame)
    if not Methods[state[f].type].Click then error("Frame cannot be clicked", 2) end
    if not f:IsVisible() then error("Cannot click hidden frame " .. tostring(state[f].name), 2) end
    f:Click(button)
end
-- A real mouse click (plan `hardware_click`): protected "hardware" functions
-- work inside its OnClick. forge.click is SDK Lua (plan `click`): they refuse.
function forge.hardwareClick(frame, button)
    local f = asFrame(frame)
    if not Methods[state[f].type].Click then error("Frame cannot be clicked", 2) end
    if not f:IsVisible() then error("Cannot click hidden frame " .. tostring(state[f].name), 2) end
    withHardware(true, f.Click, f, button)
end
function forge.blocked() return W.blocked end
function forge.protectedCalls() return W.protectedCalls end
-- Find a visible region whose text equals `text` (or contains it with plain=true).
function forge.findText(text, contains)
    for _, obj in ipairs(W.objects) do
        local s = state[obj]
        local value = (s.type == "FontString" or s.type == "EditBox") and s.text
            or (s.fontString and state[s.fontString].text)
        if type(value) == "string" and (value == text or (contains and sfind(value, text, 1, true)))
            and obj:IsVisible() then
            return obj
        end
    end
    return nil
end
-- forge.wheel(frame, delta): turn the mouse wheel over a frame (1 = up, -1 = down).
function forge.wheel(frame, delta)
    local f = asFrame(frame)
    if not f:IsVisible() then error("Cannot scroll hidden frame " .. tostring(state[f].name), 2) end
    runScript(f, "OnMouseWheel", delta)
end
-- forge.clickText(text[, button[, { hardware = true }]]): hardware = a real
-- mouse click, like forge.hardwareClick.
function forge.clickText(text, button, opts)
    local obj = forge.findText(text)
    if not obj then error("No visible text " .. tostring(text), 2) end
    while obj and not Methods[state[obj].type].Click do obj = state[obj].parent end
    if not obj then error("Text " .. tostring(text) .. " is not inside a clickable frame", 2) end
    withHardware(opts and opts.hardware, obj.Click, obj, button)
end
function forge.rect(frame)
    local r = rectOf(asFrame(frame))
    if r then return { left = r.l, top = r.t, right = r.r, bottom = r.b, width = r.r - r.l, height = r.t - r.b } end
end

local function describe(obj)
    local s = state[obj]
    if s.name then return s.name end
    local text = s.text or (s.fontString and state[s.fontString].text)
    if type(text) == "string" and text ~= "" then
        return s.type .. ' "' .. ssub(plainText(text), 1, 28) .. '"'
    end
    return s.type .. " in " .. (s.parent and describe(s.parent) or "?")
end

-- Layout problems under `root`: visible siblings that overlap, and visible
-- children that stick out of their parent (inside a backdrop's insets).
-- Textures are backgrounds by nature and are ignored.
function forge.layoutIssues(root, tolerance)
    tolerance = tolerance or 1
    local issues = {}
    local function visibleKids(frame)
        local kids = {}
        for _, kid in ipairs(state[frame].children) do
            local ks = state[kid]
            local text = ks.type == "FontString" and ks.text
            if ks.type ~= "Texture" and kid:IsVisible() and not (ks.type == "FontString" and (text == nil or text == "")) then
                local r = rectOf(kid)
                if r and r.r - r.l > 0 and r.t - r.b > 0 then table.insert(kids, { obj = kid, r = r }) end
            end
        end
        return kids
    end
    local function walk(frame)
        local pr = rectOf(frame)
        local inset = 0
        local bd = state[frame].backdrop
        if type(bd) == "table" and type(bd.insets) == "table" then inset = tonumber(bd.insets.left) or 0 end
        local kids = visibleKids(frame)
        for i, a in ipairs(kids) do
            if pr then
                local out = math.max(pr.l + inset - a.r.l, a.r.r - (pr.r - inset), a.r.t - (pr.t - inset), pr.b + inset - a.r.b)
                if out > tolerance then
                    table.insert(issues, sformat("%s sticks out of %s by %d px", describe(a.obj), describe(frame), math.ceil(out)))
                end
            end
            for j = i + 1, #kids do
                local b = kids[j]
                local ox = math.min(a.r.r, b.r.r) - math.max(a.r.l, b.r.l)
                local oy = math.min(a.r.t, b.r.t) - math.max(a.r.b, b.r.b)
                if ox > tolerance and oy > tolerance then
                    table.insert(issues, sformat("%s overlaps %s", describe(a.obj), describe(b.obj)))
                end
            end
            if Methods[state[a.obj].type].CreateFontString then walk(a.obj) end
        end
    end
    walk(asFrame(root))
    return issues
end
-- forge.sketch(name, root) records what `root` would draw (backdrops, colored
-- textures, text with its color and size), in draw order, so the spec runner
-- can save it as an SVG picture: look at layouts with realistic data (a full
-- raid, long names) that a live test cannot produce. Estimated text widths,
-- default fonts; no textures from files. A picture to review, not proof.
local FONT_COLORS = { Highlight = { 1, 1, 1 }, Disable = { 0.5, 0.5, 0.5 } }
local function fontColor(obj)
    local s = state[obj]
    if s.color then return s.color end
    local fo = s.fontObject
    local name = type(fo) == "string" and fo or (fo and state[fo] and state[fo].name) or ""
    for key, color in pairs(FONT_COLORS) do
        if sfind(name, key, 1, true) then return color end
    end
    return { 1, 0.82, 0 }
end
function forge.sketch(name, root)
    root = asFrame(root)
    local rr = rectOf(root)
    if not rr or not root:IsVisible() then error("forge.sketch needs a visible, placed frame", 2) end
    local items = {}
    local function add(obj, kind, extra)
        local r = rectOf(obj)
        if not r or r.r - r.l <= 0 or r.t - r.b <= 0 then return end
        extra.kind, extra.x, extra.y = kind, r.l - rr.l, rr.t - r.t
        extra.w, extra.h = r.r - r.l, r.t - r.b
        tinsert(items, extra)
    end
    local function walk(frame)
        local s = state[frame]
        if type(s.backdrop) == "table" then
            add(frame, "box", { color = s.backdropColor or { 0, 0, 0, 1 },
                                border = s.backdrop.edgeFile and (s.borderColor or { 1, 1, 1, 1 }) or nil })
        end
        if s.type == "EditBox" then
            add(frame, "box", { color = { 0, 0, 0, 0.5 }, border = { 0.5, 0.5, 0.5, 1 } })
            if s.text and s.text ~= "" then add(frame, "text", { text = plainText(s.text), size = 12, color = { 1, 1, 1 } }) end
        end
        -- Regions first, then child frames by frame level (as the client draws).
        local kids = {}
        for i, kid in ipairs(s.children) do kids[i] = kid end
        local order = {}
        for i, kid in ipairs(kids) do order[kid] = i end
        local function level(kid)
            local ks = state[kid]
            if not Methods[ks.type].CreateFontString then return -1 end
            return ks.level or 0
        end
        table.sort(kids, function(a, b)
            if level(a) ~= level(b) then return level(a) < level(b) end
            return order[a] < order[b]
        end)
        for _, kid in ipairs(kids) do
            local ks = state[kid]
            if kid:IsVisible() then
                if ks.type == "Texture" then
                    if ks.color then add(kid, "box", { color = ks.color }) end
                elseif ks.type == "FontString" then
                    if ks.text and ks.text ~= "" then
                        add(kid, "text", { text = plainText(ks.text), size = fontSize(kid), color = fontColor(kid),
                                           justify = ks.justifyH, clip = ks.wordWrap == false or nil })
                    end
                elseif Methods[ks.type].CreateFontString then
                    walk(kid)
                end
            end
        end
    end
    walk(root)
    W.sketches = W.sketches or {}
    tinsert(W.sketches, { name = tostring(name), width = rr.r - rr.l, height = rr.t - rr.b, items = items })
end
function forge.setSaved(name, value) if not W.reloaded then W.saved[name] = value end end
function forge.type(editbox, text)
    local f = asFrame(editbox)
    state[f].text = tostring(text)
    runScript(f, "OnTextChanged", true)
end
function forge.press(editbox, key)
    local f = asFrame(editbox)
    local script = ({ ENTER = "OnEnterPressed", ESCAPE = "OnEscapePressed", TAB = "OnTabPressed" })[key]
    if not script then error("forge.press supports ENTER, ESCAPE, TAB", 2) end
    -- Enter in an edit box is a hardware event (client CSimpleEditBox key handling).
    withHardware(key == "ENTER", runScript, f, script)
end
function forge.frame(name) return rawget(W.env, name) end
function forge.text(frame) local f = asFrame(frame); return f.GetText and f:GetText() end
function forge.shown(frame) return asFrame(frame):IsVisible() end
function forge.chat() return W.chat end
function forge.lastChat() return W.chat[#W.chat] end
function forge.sent() return W.sent end
function forge.popups() return W.popups end
function forge.sounds() return W.sounds end
function forge.time() return W.time end
-- A stub of a protected function keeps its protection: the spec models
-- what the server does, not whether the client lets the addon call it.
function forge.stub(name, value)
    if PROTECTED[name] and type(value) == "function" then value = protected(name, PROTECTED[name], value) end
    rawset(W.env, name, value)
end
function forge.unit(token, fields)
    token = slower(token)
    if fields == false then W.units[token] = nil; return end
    local u = W.units[token] or { isPlayer = true, connected = true, level = 80, health = 1, maxHealth = 1 }
    for k, v in pairs(fields or {}) do u[k] = v end
    W.units[token] = u
    return u
end
function forge.party(names)
    for i = 1, 4 do W.units["party" .. i] = nil end
    for i, name in ipairs(names) do
        local d = type(name) == "table" and name or { name = name }
        d.party, d.isPlayer = true, true
        d.class, d.classToken = d.class or "Warrior", d.classToken or "WARRIOR"
        W.units["party" .. i] = d
    end
    W.partyCount = #names
    fire("PARTY_MEMBERS_CHANGED")
end
function forge.raid(names)
    W.raid = {}
    for i, name in ipairs(names) do
        local d = type(name) == "table" and name or { name = name }
        d.raidIndex = i
        W.raid[i] = d
        W.units["raid" .. i] = d
    end
    fire("RAID_ROSTER_UPDATE")
end
function forge.leader(value) W.leader = value and true or false end
function forge.masterLoot(candidates) W.lootMethod = { method = "master", party = 0, raid = 1 }; W.lootCandidates = candidates or {} end
function forge.item(id, fields) fields.id = id; W.items[id] = fields; return fields end
function forge.openLoot(items)
    W.loot = {}
    for i, item in ipairs(items) do
        local entry = type(item) == "table" and item or { link = item }
        if entry.id and W.items[entry.id] then
            local def = W.items[entry.id]
            entry.link, entry.name, entry.quality = entry.link or def.link, entry.name or def.name, entry.quality or def.quality
        end
        W.loot[i] = entry
    end
    W.lootOpen = true
    W.env.LootFrame:Show()
    fire("LOOT_OPENED", 0)
end
function forge.closeLoot() W.env.CloseLoot() end
function forge.awards() return W.awards end
function forge.addonMessages() return W.addonMessages end
-- Lines of GameTooltip and whether it is shown (after forge.hover).
function forge.tooltip()
    local tip = W.env.GameTooltip
    return state[tip].lines or {}, tip:IsShown() and true or false
end
function forge.hover(frame, leave)
    local f = asFrame(frame)
    runScript(f, leave and "OnLeave" or "OnEnter")
end
-- Trade `links` (item links in the player's trade slots) to `partner`: the
-- partner accepts, then the player calls AcceptTrade(). opts.cancel cancels
-- instead; opts.infoFirst sends "Trade complete." before TRADE_CLOSED;
-- opts.clearOnComplete empties the trade slots (TRADE_PLAYER_ITEM_CHANGED)
-- before the completion message, as the items leave on completion.
function forge.trade(partner, links, opts)
    opts = opts or {}
    W.units.npc = { name = partner, isPlayer = true, connected = true }
    W.trade = { items = {} }
    fire("TRADE_SHOW")
    for i, link in ipairs(links or {}) do
        W.trade.items[i] = link
        fire("TRADE_PLAYER_ITEM_CHANGED", i)
    end
    fire("TRADE_ACCEPT_UPDATE", 0, 1)
    if not opts.cancel then withHardware(true, W.env.AcceptTrade) end
    if opts.clearOnComplete and not opts.cancel then
        for i in ipairs(links or {}) do
            W.trade.items[i] = nil
            fire("TRADE_PLAYER_ITEM_CHANGED", i)
        end
    end
    local info = opts.cancel and W.env.ERR_TRADE_CANCELLED or W.env.ERR_TRADE_COMPLETE
    if opts.infoFirst then fire("UI_INFO_MESSAGE", info) end
    W.trade = nil
    W.units.npc = nil
    fire("TRADE_CLOSED")
    if not opts.infoFirst then fire("UI_INFO_MESSAGE", info) end
end
function forge.roll(name, value, lo, hi)
    fire("CHAT_MSG_SYSTEM", wowFormat(W.env.RANDOM_ROLL_RESULT, name, value, lo or 1, hi or 100))
end
function forge.nextRoll(value) tinsert(W.nextRolls, value) end
function forge.combat(on)
    W.combat = on and true or false
    fire(on and "PLAYER_REGEN_DISABLED" or "PLAYER_REGEN_ENABLED")
end
function forge.keys(mods) W.keys = mods or {} end
function forge.zone(zone, subzone, x, y) W.zone, W.mapX, W.mapY = zone, x or W.mapX, y or W.mapY; fire("ZONE_CHANGED_NEW_AREA") end
function forge.gameTime(hour, minute) W.gameMinutes = (hour * 60 + (minute or 0)) - W.time / 60 end
function forge.locale(locale, strings)
    W.locale = locale
    for k, v in pairs(strings or {}) do W.strings[k] = v; rawset(W.env, k, v) end
end
function forge.saved(name)
    if name then return rawget(W.env, name) end
    local out = {}
    for _, n in ipairs(W.savedNames) do out[n] = rawget(W.env, n) end
    return out
end
function forge.errors() return currentTest and currentTest.errors or report.errors end

---------------------------------------------------------------- expect()
local function same(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
local function show(v) return type(v) == "table" and json(v) or tostring(v) end

local function expect(actual)
    local m = {}
    local function check(ok, message) if not ok then error(message, 3) end return m end
    function m.toBe(expected) return check(actual == expected, "expected " .. show(expected) .. ", got " .. show(actual)) end
    function m.toEqual(expected) return check(same(actual, expected), "expected " .. show(expected) .. ", got " .. show(actual)) end
    function m.toBeTruthy() return check(actual, "expected a truthy value, got " .. show(actual)) end
    function m.toBeFalsy() return check(not actual, "expected a falsy value, got " .. show(actual)) end
    function m.toBeNil() return check(actual == nil, "expected nil, got " .. show(actual)) end
    function m.toBeGreaterThan(n) return check(type(actual) == "number" and actual > n, "expected > " .. show(n) .. ", got " .. show(actual)) end
    function m.toBeLessThan(n) return check(type(actual) == "number" and actual < n, "expected < " .. show(n) .. ", got " .. show(actual)) end
    function m.toMatch(pattern) return check(type(actual) == "string" and sfind(actual, pattern) ~= nil, "expected " .. show(actual) .. " to match " .. pattern) end
    function m.toContain(needle)
        if type(actual) == "string" then return check(sfind(actual, needle, 1, true) ~= nil, "expected " .. show(actual) .. " to contain " .. show(needle)) end
        if type(actual) == "table" then
            for _, v in pairs(actual) do
                if same(v, needle) or (type(v) == "string" and type(needle) == "string" and sfind(v, needle, 1, true)) then return m end
                if type(v) == "table" and type(needle) == "string" and type(v.message) == "string" and sfind(v.message, needle, 1, true) then return m end
            end
        end
        return check(false, "expected " .. show(actual) .. " to contain " .. show(needle))
    end
    function m.toBeShown() local f = asFrame(actual); return check(f:IsVisible(), (state[f].name or "frame") .. " is not visible") end
    function m.toBeHidden() local f = asFrame(actual); return check(not f:IsVisible(), (state[f].name or "frame") .. " is visible") end
    return m
end

---------------------------------------------------------------- orchestration
local tests, hooks = {}, {}

local function specEnv()
    return setmetatable({ forge = forge, expect = expect,
        test = function(name, fn) tinsert(tests, { name = name, fn = fn }) end,
        before_load = function(fn) tinsert(hooks, fn) end,
    }, { __index = function(_, k) return W.env[k] end, __newindex = function(_, k, v) W.env[k] = v end })
end

local config, files, loadErrorsSeen

local function loadAddon(saved, reloaded)
    local E = newWorld(config, saved)
    W.reloaded = reloaded
    local ns = {}
    for _, hook in ipairs(hooks) do
        local ok, err = budgeted(hook)
        if not ok then tinsert(report.load_errors, "before_load: " .. tostring(err)) end
    end
    for _, file in ipairs(files) do
        local chunk, err = real_loadstring(file.source, "@" .. file.name)
        if not chunk then
            tinsert(report.load_errors, tostring(err))
        else
            real_setfenv(chunk, E)
            local ok, rerr = budgeted(chunk, config.addonName, ns)
            if not ok then tinsert(report.load_errors, tostring(rerr)) end
        end
    end
    -- The client runs the SavedVariables file after the addon's files, in a
    -- scratch table, and copies only the values it set (client LoadAddOn,
    -- FrameScript_LoadVariables): a variable saved as nil, or never saved,
    -- keeps what the addon's files assigned.
    for _, name in ipairs(W.savedNames) do
        if W.saved[name] ~= nil then rawset(E, name, deepcopy(W.saved[name])) end
    end
    fire("ADDON_LOADED", config.addonName)
    -- VARIABLES_LOADED waits for the account data: at login it arrives after
    -- world entry; on /reload it is cached and fires before PLAYER_LOGIN
    -- (client LoadAccountVariables, CGGameUI::InitializeFrameXML).
    if reloaded then fire("VARIABLES_LOADED") end
    fire("PLAYER_LOGIN")
    fire("PLAYER_ENTERING_WORLD")
    if not reloaded then fire("VARIABLES_LOADED") end
end

-- Simulates /reload: SavedVariables persist, everything else is rebuilt.
-- The client leaves the world before it logs the UI out (CGGameUI::Shutdown).
function forge.reload()
    fire("PLAYER_LEAVING_WORLD")
    fire("PLAYER_LOGOUT")
    local persisted = {}
    for _, name in ipairs(W.savedNames) do persisted[name] = deepcopy(rawget(W.env, name)) end
    loadAddon(persisted, true)
end

function H.run(configJson, fileList, specSource, specName)
    config = configJson
    files = fileList
    if specSource then
        local chunk, err = real_loadstring(specSource, "@" .. specName)
        if not chunk then
            tinsert(report.load_errors, "spec: " .. tostring(err))
        else
            real_setfenv(chunk, specEnv())
            local ok, serr = budgeted(chunk)
            if not ok then tinsert(report.load_errors, "spec: " .. tostring(serr)) end
        end
    end
    loadAddon(config.saved or {})
    for _, t in ipairs(tests) do
        currentTest = { name = t.name, errors = {} }
        local ok, err = budgeted(t.fn)
        if not ok then
            currentTest.status, currentTest.error = "failed", tostring(err)
        elseif #currentTest.errors > 0 then
            currentTest.status, currentTest.error = "failed", "Lua error in a script handler during the test"
        else
            currentTest.status = "passed"
        end
        tinsert(report.tests, currentTest)
        currentTest = nil
    end
    report.sketches = W.sketches
    report.chat = W.chat
    report.sent = W.sent
    return json(report)
end

return H
