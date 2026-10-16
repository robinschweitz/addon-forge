-- ForgeLootLedger: raid roll and master-loot award ledger for WoW 3.3.5a / Lua 5.1.
-- Records who really received each item (master-loot handouts, confirmed by the
-- loot chat line), follows trades of items the master looter kept, allows manual
-- corrections and exports the ledger for the raid website (RS2;LOOT).
local addonName = ...
local Ledger = CreateFrame("Frame", "ForgeLootLedgerFrame", UIParent)
local MAX_HISTORY = 250
local MAX_ACTIVE = 10
local HISTORY_LINES = 4
local ROLL_SECONDS = 30
local TIE_SECONDS = 15
local TRADE_GRACE = 5   -- seconds a closed trade window may still report "Trade complete."
local EXPORT_FORMAT = "RS2"
-- Tokens are not counted in the item tally (matched in the item link's name).
local TOKEN_NAMES = { "Weiheabzeichen" }
local SPEC_NAMES = { ms = "main spec", os = "off spec" }

local active = {}
local selected          -- the selected entry table (not an index: inserts shift indices)
local editing           -- the history record whose recipient is being corrected
local lootSlots = {}    -- slot -> { entry = active entry, link = item link } of the open loot window
local drops = {}        -- source:slot:link -> entry, so reopening a corpse does not duplicate items
local windowKey, windowNpc
local windowCount = 0
local lastKill          -- { guid, npc } of the latest creature death, for chests
local trade             -- { partner, items, closedAt } of the open or just closed trade
local patterns = {}
local historyOffset = 0
local rollOffset = 0
local syncAt            -- when to ask the group for the shared ledger (after login)
local rows = {}

local function trim(value)
    return (value or ""):match("^%s*(.-)%s*$")
end

local function lower(value)
    return string.lower(value or "")
end

-- field strips characters that would break the export or the ledger display.
local function field(value)
    return (string.gsub(value or "", "[|;\r\n]", ""))
end

local function itemIDFromLink(link)
    if type(link) ~= "string" then return nil end
    return tonumber(string.match(link, "item:(%d+)"))
end

-- npcFromGUID reads the creature ID from a 3.3.5a GUID such as 0xF130003B6900182E.
local function npcFromGUID(guid)
    if type(guid) ~= "string" then return nil end
    local kind = string.sub(guid, 3, 5)
    if kind ~= "F13" and kind ~= "F15" then return nil end
    return tonumber(string.sub(guid, 9, 12), 16)
end

-- patternFromFormat turns a client format string (LOOT_ITEM, RANDOM_ROLL_RESULT)
-- into an anchored Lua pattern. Localized clients use positional specifiers
-- ("%1$s" on deDE); "%1" would otherwise become an invalid back-reference.
local function patternFromFormat(format)
    if type(format) ~= "string" or format == "" then return nil end
    format = format:gsub("%%%d+%$", "%%")
    format = format:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    format = format:gsub("%%s", "(.-)")
    format = format:gsub("%%d", "(%%d+)")
    return "^" .. format .. "$"
end

local function playerName()
    return UnitName("player") or ""
end

local function isPlayer(name)
    return lower(name) == lower(playerName())
end

local function say(text)
    DEFAULT_CHAT_FRAME:AddMessage("ForgeLootLedger: " .. text)
end

-- announce goes to raid chat in a raid, party chat in a party, else local chat.
local function announce(text)
    if GetNumRaidMembers() and GetNumRaidMembers() > 0 then
        SendChatMessage(text, "RAID")
    elseif GetNumPartyMembers() and GetNumPartyMembers() > 0 then
        SendChatMessage(text, "PARTY")
    else
        DEFAULT_CHAT_FRAME:AddMessage("ForgeLootLedger: " .. text)
    end
end

-- Loot rules (decided by the raid): /rnd 100 is main spec, /rnd 99 off spec.
-- Points enhance a main-spec roll in steps of 10, up to 51-150 (11-110,
-- 21-120, ...). Main spec always beats off spec; within one spec the player with
-- the fewest items this raid wins, and the roll decides between equal tallies.
local function rollKind(low, high)
    if low == 1 and high == 100 then return "ms" end
    if low == 1 and high == 99 then return "os" end
    if high == low + 99 and low >= 11 and low <= 51 and (low - 1) % 10 == 0 then return "ms" end
end

local function isToken(link)
    for _, name in ipairs(TOKEN_NAMES) do
        if string.find(link or "", name, 1, true) then return true end
    end
    return false
end

-- rollLabel describes a counted roll: "MS", "MS 21-120" (with points) or "OS".
local function rollLabel(r)
    if r.kind == "os" then return "OS" end
    if r.low and r.low > 1 then return "MS " .. r.low .. "-" .. r.high end
    return "MS"
end

local function itemCount(n)
    return n == 1 and "1 item" or (n .. " items")
end

-- ranksAbove orders counted rolls: main spec first, then the fewest items, then
-- the highest roll.
local function ranksAbove(a, b)
    if a.kind ~= b.kind then return a.kind == "ms" end
    if (a.tally or 0) ~= (b.tally or 0) then return (a.tally or 0) < (b.tally or 0) end
    return a.value > b.value
end

local function ensureDatabase()
    ForgeLootLedgerDB = ForgeLootLedgerDB or {}
    local db = ForgeLootLedgerDB
    db.history = db.history or {}
    db.nextID = db.nextID or 0
    -- Records from version 1.0 have no stable ID yet; number them oldest first.
    for i = table.getn(db.history), 1, -1 do
        local record = db.history[i]
        if not record.id then
            db.nextID = db.nextID + 1
            record.id = db.nextID
            record.itemID = record.itemID or itemIDFromLink(record.item)
            record.state = record.state or "manual"
            record.confirmed = true
        end
    end
    return db
end

local function findRecord(id)
    for _, record in ipairs(ensureDatabase().history) do
        if record.id == id then return record end
    end
end

-- tallies counts this raid's awards per player and spec ({ ms = n, os = n }),
-- keyed by lower-case name. Tokens, removed awards and awards without a spec
-- (handed out without a roll) do not count; a held item counts for its winner.
local function tallies()
    local counts = {}
    for _, r in ipairs(ensureDatabase().history) do
        if (r.spec == "ms" or r.spec == "os") and r.state ~= "deleted" and not r.token then
            local key = lower((r.state == "held" and r.winner) or r.recipient)
            counts[key] = counts[key] or { ms = 0, os = 0 }
            counts[key][r.spec] = counts[key][r.spec] + 1
        end
    end
    return counts
end

local function tallyOf(counts, name, kind)
    local entry = counts[lower(name)]
    return entry and entry[kind] or 0
end

local function summaryLine(name)
    local counts = tallies()
    return string.format("%s this raid: %d main spec, %d off spec (tokens not counted)",
        name, tallyOf(counts, name, "ms"), tallyOf(counts, name, "os"))
end

-- announceAward tells the raid who got an item, so nobody has to ask.
local function announceAward(record, how)
    local spec = record.spec and (" - " .. SPEC_NAMES[record.spec]) or ""
    announce(string.format("[Loot] %s goes to %s%s%s.", record.item, record.recipient, spec,
        how and (" (" .. how .. ")") or ""))
end

local function isActive(entry)
    for _, candidate in ipairs(active) do
        if candidate == entry then return true end
    end
    return false
end

-- sortedRollLog copies an entry's roll log for the ledger: by round (1 = the
-- roll, 2+ = tie-breaks), counted rolls in winning order (main spec, fewest
-- items, highest roll), then ignored rolls in the order they came in.
local function sortedRollLog(entry)
    if not entry.rollLog then return {} end
    local counts = tallies()
    local log = {}
    for index, r in ipairs(entry.rollLog) do
        local copy = { name = r.name, value = r.value, round = r.round, note = r.note, order = index,
            kind = r.kind, low = r.low, high = r.high }
        if r.kind and not r.note then copy.tally = tallyOf(counts, r.name, r.kind) end
        table.insert(log, copy)
    end
    table.sort(log, function(a, b)
        if a.round ~= b.round then return a.round < b.round end
        if (a.note == nil) ~= (b.note == nil) then return a.note == nil end
        if a.note == nil and (a.kind ~= b.kind or a.tally ~= b.tally or a.value ~= b.value) then
            return ranksAbove(a, b)
        end
        return a.order < b.order
    end)
    for _, r in ipairs(log) do r.order = nil end
    return log
end

---------------------------------------------------------------------------
-- Shared ledger: every award change goes to the other addon users in the
-- group, so officers see the same list and a crashed master looter can get
-- the ledger back (/forgeloot sync).
---------------------------------------------------------------------------
local SYNC_PREFIX = "FLLedger"
local outbox = {}
local NOTE_CODES = { ["re-roll"] = "r", ["not in tie-break"] = "t" }

local function groupChannel()
    if GetNumRaidMembers() and GetNumRaidMembers() > 0 then return "RAID" end
    if GetNumPartyMembers() and GetNumPartyMembers() > 0 then return "PARTY" end
end

local function queue(message)
    if groupChannel() then table.insert(outbox, message) end
end

-- currentSession names this raid's ledger; it changes with every new raid.
local function currentSession()
    local db = ensureDatabase()
    db.session = db.session or (field(playerName()) .. "-" .. time())
    return db.session
end

local function encodeRecord(r)
    return table.concat({ "A", currentSession(), field(r.origin or playerName()), r.id, r.rev or 1, r.at or 0,
        r.itemID or "", r.npc or "", field(r.recipient), r.state or "manual", r.confirmed and 1 or 0,
        r.spec or "", r.roll or "", r.low or "", r.high or "", field(r.winner or ""), r.rolls or 0,
        r.token and 1 or "", r.time or "" }, ";")
end

-- encodeLog splits a roll log into messages of at most ~200 characters.
local function encodeLog(r)
    local entries = {}
    for _, e in ipairs(r.rollLog or {}) do
        local code = e.note and (NOTE_CODES[e.note] or "x") or ""
        table.insert(entries, table.concat({ field(e.name), e.value, e.low or 1, e.high or 100, e.round or 1,
            code, e.tally or "" }, ","))
    end
    local parts, current = {}, {}
    local length = 0
    for _, entry in ipairs(entries) do
        if length + string.len(entry) > 160 and table.getn(current) > 0 then
            table.insert(parts, current)
            current, length = {}, 0
        end
        table.insert(current, entry)
        length = length + string.len(entry) + 1
    end
    if table.getn(current) > 0 then table.insert(parts, current) end
    local messages = {}
    for index, part in ipairs(parts) do
        table.insert(messages, table.concat({ "L", currentSession(), field(r.origin or playerName()), r.id,
            index, table.getn(parts), table.concat(part, "/") }, ";"))
    end
    return messages
end

-- publish sends a changed award (with its roll log when withLog is set).
local function publish(record, withLog)
    record.origin = record.origin or playerName()
    record.rev = (record.rev or 0) + 1
    queue(encodeRecord(record))
    if withLog then
        for _, message in ipairs(encodeLog(record)) do queue(message) end
    end
end

local function findRoll(entry, name)
    for _, r in ipairs(entry.rolls or {}) do
        if lower(r.name) == lower(name) then return r end
    end
end

-- recordAward stores an award and removes the item from the active list.
-- Items the recorder gives to himself are "held" until a trade or a correction.
-- The award's spec comes from the recipient's roll, or for a held item from
-- the roll winner's (the master looter passes it on later).
local function recordAward(entry, recipient, state, confirmed)
    local db = ensureDatabase()
    local winner = entry.winner and entry.winner.name
    local roll = findRoll(entry, recipient)
    if not roll and isPlayer(recipient) and winner then roll = findRoll(entry, winner) end
    local log = sortedRollLog(entry)   -- before this award changes the tallies
    db.nextID = db.nextID + 1
    local record = {
        id = db.nextID,
        item = entry.item or "Unknown item",
        itemID = itemIDFromLink(entry.item),
        npc = entry.npc,
        recipient = field(recipient),
        state = isPlayer(recipient) and "held" or state,
        confirmed = confirmed and true or false,
        rolls = table.getn(entry.rolls or {}),
        roll = roll and roll.value,
        spec = roll and roll.kind,
        low = roll and roll.low,
        high = roll and roll.high,
        winner = winner,
        token = isToken(entry.item) or nil,
        rollLog = log,
        time = date("%H:%M"),
        at = time(),
    }
    table.insert(db.history, 1, record)
    db.startedAt = db.startedAt or record.at
    while table.getn(db.history) > MAX_HISTORY do
        table.remove(db.history)
    end
    entry.record = record
    publish(record, true)
    for index = table.getn(active), 1, -1 do
        if active[index] == entry then table.remove(active, index) end
    end
    if selected == entry then selected = nil end
    historyOffset = 0
    return record
end

-- buildExport renders "RS2;LOOT;<raidID>;<recorder>;<startedAt>;<exportedAt>"
-- followed by "<id>;<awardedAt>;<npcID or ->;<itemID or ->;<recipient>;<state>;
-- <roll or ->;<ms|os|->;<low-high or ->" per award, oldest first. The range shows
-- enhanced rolls (e.g. 21-120), whose points the website deducts. IDs never change, so the website can update lines it
-- already imported; removed awards stay in the export as "deleted" tombstones.
-- The separator is ";" because "|" starts escape sequences ("|T", "|c") in a
-- WoW EditBox, and character names cannot contain ";".
local function buildExport(raidID, recorder, startedAt, exportedAt, history)
    local lines = { table.concat({ EXPORT_FORMAT, "LOOT", tostring(raidID), field(recorder),
        tostring(startedAt or exportedAt), tostring(exportedAt) }, ";") }
    for i = table.getn(history), 1, -1 do
        local r = history[i]
        lines[table.getn(lines) + 1] = table.concat({ tostring(r.id), tostring(r.at or 0),
            r.npc and tostring(r.npc) or "-", r.itemID and tostring(r.itemID) or "-",
            field(r.recipient), r.state or "manual", r.roll and tostring(r.roll) or "-",
            r.spec or "-", r.low and (r.low .. "-" .. r.high) or "-" }, ";")
    end
    return table.concat(lines, "\n")
end

local function makeBackdrop(frame, red, green, blue, alpha)
    frame:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(red, green, blue, alpha)
    frame:SetBackdropBorderColor(0.20, 0.63, 0.82, 0.92)
end

local function label(parent, template, size, color)
    local text = parent:CreateFontString(nil, "OVERLAY", template)
    if size then text:SetFont(STANDARD_TEXT_FONT, size) end
    if color then text:SetTextColor(color[1], color[2], color[3]) end
    return text
end

local function flatButton(parent, caption, width)
    local button = CreateFrame("Button", nil, parent)
    button:SetWidth(width)
    button:SetHeight(24)
    makeBackdrop(button, 0.08, 0.25, 0.34, 0.98)
    local text = label(button, "GameFontNormal", 10, {0.70, 0.93, 1.00})
    text:SetPoint("CENTER", button, "CENTER", 0, 0)
    button:SetFontString(text)
    button:SetText(caption)
    return button
end

Ledger:SetWidth(600)
Ledger:SetHeight(430)
Ledger:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
Ledger:SetFrameStrata("DIALOG")
Ledger:SetClampedToScreen(true)
Ledger:EnableMouse(true)
Ledger:SetMovable(true)
Ledger:RegisterForDrag("LeftButton")
Ledger:SetScript("OnDragStart", function(self) self:StartMoving() end)
Ledger:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
makeBackdrop(Ledger, 0.018, 0.031, 0.055, 0.97)

local accent = Ledger:CreateTexture(nil, "ARTWORK")
accent:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
accent:SetPoint("TOPLEFT", Ledger, "TOPLEFT", 10, -9)
accent:SetPoint("TOPRIGHT", Ledger, "TOPRIGHT", -10, -9)
accent:SetHeight(2)
accent:SetVertexColor(0.25, 0.78, 1.00, 0.95)

local title = label(Ledger, "GameFontNormalLarge", 17, {0.54, 0.88, 1.00})
title:SetPoint("TOPLEFT", Ledger, "TOPLEFT", 18, -18)
title:SetText("MASTER LOOT LEDGER")

local subtitle = label(Ledger, "GameFontNormalSmall", 10, {0.48, 0.62, 0.72})
subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 1, -2)
subtitle:SetText("LOOT WINDOW  /  PLAYER ROLLS  /  AWARD RECORDS")

local close = CreateFrame("Button", nil, Ledger)
close:SetWidth(24)
close:SetHeight(24)
close:SetPoint("TOPRIGHT", Ledger, "TOPRIGHT", -13, -14)
makeBackdrop(close, 0.10, 0.16, 0.21, 0.95)
local closeText = label(close, "GameFontNormal", 14, {0.72, 0.84, 0.90})
closeText:SetPoint("CENTER", close, "CENTER", 0, 0)
closeText:SetText("X")
close:SetScript("OnClick", function() Ledger:Hide() end)

local exportButton = flatButton(Ledger, "EXPORT", 70)
exportButton:SetPoint("RIGHT", close, "LEFT", -8, 0)

local rollPane = CreateFrame("Frame", "ForgeLootLedgerRollPane", Ledger)
rollPane:SetPoint("TOPLEFT", Ledger, "TOPLEFT", 16, -68)
rollPane:SetWidth(336)
rollPane:SetHeight(228)
makeBackdrop(rollPane, 0.035, 0.070, 0.105, 0.97)
rollPane:EnableMouseWheel(true)

local rollHeading = label(rollPane, "GameFontNormal", 11, {1.00, 0.80, 0.32})
rollHeading:SetPoint("TOPLEFT", rollPane, "TOPLEFT", 12, -11)
rollHeading:SetText("MASTER LOOT ITEMS")

local EMPTY_ACTIVE = "Open the master loot window\nPlayers can then use /rnd"
local emptyRolls = label(rollPane, "GameFontNormalSmall", 11, {0.42, 0.61, 0.70})
emptyRolls:SetPoint("CENTER", rollPane, "CENTER", 0, 10)
emptyRolls:SetText(EMPTY_ACTIVE)
emptyRolls:SetJustifyH("CENTER")

local detailPane = CreateFrame("Frame", nil, Ledger)
detailPane:SetPoint("TOPLEFT", rollPane, "TOPRIGHT", 12, 0)
detailPane:SetWidth(220)
detailPane:SetHeight(228)
makeBackdrop(detailPane, 0.035, 0.070, 0.105, 0.97)

local detailHeading = label(detailPane, "GameFontNormal", 11, {1.00, 0.80, 0.32})
detailHeading:SetPoint("TOPLEFT", detailPane, "TOPLEFT", 12, -11)
detailHeading:SetText("AWARD SELECTED LOOT")

local itemDetail = label(detailPane, "GameFontHighlight", 12, {0.94, 0.97, 1.00})
itemDetail:SetPoint("TOPLEFT", detailPane, "TOPLEFT", 12, -34)
itemDetail:SetPoint("TOPRIGHT", detailPane, "TOPRIGHT", -12, -34)
itemDetail:SetHeight(26)
itemDetail:SetJustifyH("LEFT")
itemDetail:SetJustifyV("TOP")
itemDetail:SetText("Select an active roll")

local rollDetail = label(detailPane, "GameFontNormalSmall", 10, {0.45, 0.68, 0.80})
rollDetail:SetPoint("TOPLEFT", itemDetail, "BOTTOMLEFT", 0, -6)
rollDetail:SetPoint("TOPRIGHT", itemDetail, "BOTTOMRIGHT", 0, -6)
rollDetail:SetJustifyH("LEFT")
rollDetail:SetWordWrap(false)
rollDetail:SetText("No player rolls recorded")

local recipientBox = CreateFrame("EditBox", nil, detailPane, "InputBoxTemplate")
recipientBox:SetPoint("TOPLEFT", detailPane, "TOPLEFT", 14, -100)
recipientBox:SetWidth(198)
recipientBox:SetHeight(24)
recipientBox:SetAutoFocus(false)
recipientBox:SetMaxLetters(24)
recipientBox:SetTextInsets(5, 5, 0, 0)

local recipientHint = label(detailPane, "GameFontNormalSmall", 9, {0.45, 0.60, 0.68})
recipientHint:SetPoint("BOTTOMLEFT", recipientBox, "TOPLEFT", 1, 2)
recipientHint:SetText("RECIPIENT NAME")

local award = CreateFrame("Button", nil, detailPane)
award:SetPoint("TOPLEFT", recipientBox, "BOTTOMLEFT", -2, -10)
award:SetWidth(196)
award:SetHeight(26)
makeBackdrop(award, 0.08, 0.25, 0.34, 0.98)
local awardText = label(award, "GameFontNormal", 11, {0.70, 0.93, 1.00})
awardText:SetPoint("CENTER", award, "CENTER", 0, 0)
awardText:SetText("RECORD AWARD")

local rosterHint = label(detailPane, "GameFontNormalSmall", 9, {0.45, 0.60, 0.68})
rosterHint:SetPoint("TOPLEFT", award, "BOTTOMLEFT", 1, -9)
rosterHint:SetText("CLICK A GROUP MEMBER")

local rosterButtons = {}
for i = 1, 4 do
    local button = CreateFrame("Button", nil, detailPane)
    button:SetWidth(96)
    button:SetHeight(18)
    button:SetPoint("TOPLEFT", rosterHint, "BOTTOMLEFT", -1 + ((i - 1) % 2) * 100, -5 - math.floor((i - 1) / 2) * 21)
    makeBackdrop(button, 0.045, 0.09, 0.13, 0.98)
    -- 3.3.5a Buttons have no SetTextColor; color the button's own FontString.
    local text = label(button, "GameFontNormalSmall", nil, {0.58, 0.79, 0.88})
    text:SetPoint("LEFT", button, "LEFT", 6, 0)
    text:SetPoint("RIGHT", button, "RIGHT", -6, 0)
    text:SetWordWrap(false)
    button:SetFontString(text)
    button:SetScript("OnClick", function(self) recipientBox:SetText(self.fullName or "") end)
    rosterButtons[i] = button
end

local historyPane = CreateFrame("Frame", "ForgeLootLedgerHistoryPane", Ledger)
historyPane:SetPoint("TOPLEFT", Ledger, "TOPLEFT", 16, -306)
historyPane:SetWidth(568)
historyPane:SetHeight(94)
makeBackdrop(historyPane, 0.025, 0.052, 0.078, 0.97)
historyPane:EnableMouseWheel(true)

local historyHeading = label(historyPane, "GameFontNormal", 11, {1.00, 0.80, 0.32})
historyHeading:SetPoint("TOPLEFT", historyPane, "TOPLEFT", 12, -10)
historyHeading:SetText("RECENT AWARDS")

local clearButton = flatButton(historyPane, "CLEAR", 56)
clearButton:SetHeight(18)
clearButton:SetPoint("TOPRIGHT", historyPane, "TOPRIGHT", -8, -6)

local historySummary = label(historyPane, "GameFontNormalSmall", 9, {0.45, 0.60, 0.68})
historySummary:SetPoint("RIGHT", clearButton, "LEFT", -10, 0)
historySummary:SetJustifyH("RIGHT")

local stateLabels = { given = "GIVEN", held = "HELD BY YOU", manual = "MANUAL", deleted = "REMOVED" }
local stateColors = {
    given = {0.45, 0.85, 0.55}, held = {1.00, 0.82, 0.30},
    manual = {0.58, 0.79, 0.88}, deleted = {0.45, 0.45, 0.45},
}

local historyLines = {}
for i = 1, HISTORY_LINES do
    local line = CreateFrame("Button", nil, historyPane)
    line:SetPoint("TOPLEFT", historyPane, "TOPLEFT", 8, -26 - (i - 1) * 15)
    line:SetPoint("TOPRIGHT", historyPane, "TOPRIGHT", -8, -26 - (i - 1) * 15)
    line:SetHeight(14)
    line:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground" })
    line:SetBackdropColor(0.10, 0.21, 0.29, 0)
    local text = label(line, "GameFontNormalSmall", 10, {0.72, 0.82, 0.88})
    text:SetPoint("LEFT", line, "LEFT", 5, 0)
    text:SetPoint("RIGHT", line, "RIGHT", -96, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    line:SetFontString(text)
    line.state = label(line, "GameFontNormalSmall", 9)
    line.state:SetPoint("RIGHT", line, "RIGHT", -5, 0)
    line.state:SetJustifyH("RIGHT")
    historyLines[i] = line
end

local status = label(Ledger, "GameFontNormalSmall", 10, {0.42, 0.60, 0.68})
status:SetPoint("BOTTOMLEFT", Ledger, "BOTTOMLEFT", 18, 12)
status:SetPoint("BOTTOMRIGHT", Ledger, "BOTTOMRIGHT", -18, 12)
status:SetJustifyH("LEFT")
status:SetWordWrap(false)
status:SetText("CLICK AN AWARD FOR ITS ROLLS OR TO CHANGE ITS RECIPIENT  |  /forgeloot help")

-- Export overlay: replaces the three panes while shown.
local exportPanel = CreateFrame("Frame", "ForgeLootLedgerExportPanel", Ledger)
exportPanel:SetPoint("TOPLEFT", Ledger, "TOPLEFT", 16, -68)
exportPanel:SetWidth(568)
exportPanel:SetHeight(332)
makeBackdrop(exportPanel, 0.035, 0.070, 0.105, 0.97)
exportPanel:Hide()

local exportHeading = label(exportPanel, "GameFontNormal", 11, {1.00, 0.80, 0.32})
exportHeading:SetPoint("TOPLEFT", exportPanel, "TOPLEFT", 12, -11)
exportHeading:SetText("WEBSITE EXPORT  (" .. EXPORT_FORMAT .. " LOOT)")

local raidLabel = label(exportPanel, "GameFontNormalSmall", 9, {0.45, 0.60, 0.68})
raidLabel:SetPoint("TOPLEFT", exportPanel, "TOPLEFT", 12, -40)
raidLabel:SetText("RAID ID")

local raidBox = CreateFrame("EditBox", nil, exportPanel, "InputBoxTemplate")
raidBox:SetPoint("LEFT", raidLabel, "RIGHT", 12, 0)
raidBox:SetWidth(80)
raidBox:SetHeight(24)
raidBox:SetAutoFocus(false)
raidBox:SetNumeric(true)
raidBox:SetMaxLetters(9)

local newRaidButton = flatButton(exportPanel, "NEW RAID", 90)
newRaidButton:SetPoint("TOPRIGHT", exportPanel, "TOPRIGHT", -12, -34)
local backButton = flatButton(exportPanel, "BACK", 70)
backButton:SetPoint("RIGHT", newRaidButton, "LEFT", -8, 0)

local exportBack = CreateFrame("Frame", nil, exportPanel)
exportBack:SetPoint("TOPLEFT", exportPanel, "TOPLEFT", 10, -66)
exportBack:SetPoint("BOTTOMRIGHT", exportPanel, "BOTTOMRIGHT", -10, 10)
makeBackdrop(exportBack, 0.01, 0.02, 0.03, 0.98)

local exportScroll = CreateFrame("ScrollFrame", nil, exportBack)
exportScroll:SetPoint("TOPLEFT", exportBack, "TOPLEFT", 8, -8)
exportScroll:SetPoint("BOTTOMRIGHT", exportBack, "BOTTOMRIGHT", -8, 8)
exportScroll:EnableMouseWheel(true)

local exportText = CreateFrame("EditBox", "ForgeLootLedgerExportText", exportScroll)
exportText:SetMultiLine(true)
exportText:SetAutoFocus(false)
exportText:SetFontObject(ChatFontNormal)
exportText:SetWidth(532)
exportText:SetHeight(240)
exportScroll:SetScrollChild(exportText)
exportScroll:SetScript("OnMouseWheel", function(self, delta)
    local range = self:GetVerticalScrollRange() or 0
    local value = math.max(0, math.min(range, self:GetVerticalScroll() - delta * 28))
    self:SetVerticalScroll(value)
end)
exportText:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
exportText:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
-- Read-only: typing restores the generated text.
exportText:SetScript("OnTextChanged", function(self, userInput)
    if userInput then self:SetText(self.generated or "") self:HighlightText() end
end)

local function activeRollCount(entry)
    return table.getn(entry.rolls)
end

local function selectedEntry()
    if not selected then return nil end
    for _, entry in ipairs(active) do
        if entry == selected then return entry end
    end
    selected = nil
end

-- Rolls belong to the entry whose roll is running, not to whatever row the
-- master looter happens to have selected (new loot or clicks must not steal them).
local function rollingEntry()
    local latest
    for _, entry in ipairs(active) do
        if entry.endsAt and not entry.winner and (not latest or entry.startedAt > latest.startedAt) then
            latest = entry
        end
    end
    return latest
end

-- lootSlotOf returns the slot of `entry` in the open master-loot window, if any.
local function lootSlotOf(entry)
    if not entry then return nil end
    local method = GetLootMethod()
    if method ~= "master" then return nil end
    for slot, info in pairs(lootSlots) do
        if info.entry == entry and GetLootSlotLink(slot) == info.link then return slot end
    end
end

local function candidateIndex(name)
    for i = 1, 40 do
        local candidate = GetMasterLootCandidate(i)
        if candidate and lower(candidate) == lower(name) then return i end
    end
end

local function updateRoster()
    local names = {}
    local members = GetNumRaidMembers()
    if members and members > 0 then
        for i = 1, members do
            local name = GetRaidRosterInfo(i)
            if name then table.insert(names, name) end
        end
    else
        local player = UnitName("player")
        if player then table.insert(names, player) end
        local party = GetNumPartyMembers()
        for i = 1, party do
            local name = UnitName("party" .. i)
            if name then table.insert(names, name) end
        end
    end
    for i = 1, 4 do
        local name = names[i]
        rosterButtons[i].fullName = name
        rosterButtons[i]:SetText(name or "")
        if name then rosterButtons[i]:Show() else rosterButtons[i]:Hide() end
    end
end

local function updateHistory()
    local history = ensureDatabase().history
    local total, held = table.getn(history), 0
    for _, record in ipairs(history) do
        if record.state == "held" then held = held + 1 end
    end
    historyOffset = math.max(0, math.min(historyOffset, total - HISTORY_LINES))
    historyHeading:SetText(total > 0 and string.format("AWARDS (%d)", total) or "RECENT AWARDS")
    historySummary:SetText(held > 0 and string.format("%d HELD BY YOU  |  SCROLL FOR MORE", held)
        or (total > HISTORY_LINES and "SCROLL FOR MORE" or ""))
    for i = 1, HISTORY_LINES do
        local line = historyLines[i]
        local record = history[i + historyOffset]
        line.record = record
        if record then
            local text = string.format("#%d  %s  |  %s  ->  %s  (%d rolls)", record.id, record.time or "",
                record.item, record.recipient, record.rolls or 0)
            if record.state == "deleted" then text = "|cff777777" .. string.gsub(text, "|c%x%x%x%x%x%x%x%x", "") .. "|r" end
            line:SetText(text)
            local stateText = stateLabels[record.state] or string.upper(record.state or "")
            if record.state == "held" and not isPlayer(record.recipient) then stateText = "HELD" end
            if string.sub(record.item or "", 1, 5) == "item:" then
                record.item = select(2, GetItemInfo(record.itemID or 0)) or record.item   -- now cached?
            end
            if not record.confirmed and record.state ~= "deleted" then stateText = stateText .. "?" end
            local color = stateColors[record.state] or stateColors.manual
            line.state:SetText(stateText)
            line.state:SetTextColor(color[1], color[2], color[3])
            line:SetBackdropColor(0.10, 0.21, 0.29, editing == record and 0.98 or 0)
            line:Show()
        else
            line:SetText(i == 1 and "No awards recorded in this ledger." or "")
            line.state:SetText("")
            line:SetBackdropColor(0.10, 0.21, 0.29, 0)
            if i == 1 then line:Show() else line:Hide() end
        end
    end
end

local function updateSelection()
    if editing then
        itemDetail:SetText(string.format("#%d %s", editing.id, editing.item))
        rollDetail:SetText(string.format("NOW: %s (%s)", editing.recipient, stateLabels[editing.state] or editing.state or ""))
        awardText:SetText(editing.state == "deleted" and "RESTORE + SET RECIPIENT" or "CHANGE RECIPIENT")
        return
    end
    local entry = selectedEntry()
    awardText:SetText(lootSlotOf(entry) and "GIVE LOOT + RECORD" or "RECORD AWARD")
    if entry then
        itemDetail:SetText(entry.item)
        if entry.winner then
            rollDetail:SetText(string.format("WINNER: %s (%d)", entry.winner.name, entry.winner.value))
        elseif entry.endsAt then
            rollDetail:SetText(string.format("%d rolls  |  %ds remaining", activeRollCount(entry), math.max(0, math.ceil(entry.endsAt - GetTime()))))
        else
            rollDetail:SetText(string.format("%d player rolls recorded", activeRollCount(entry)))
        end
    else
        itemDetail:SetText("Select an active roll")
        rollDetail:SetText("No player rolls recorded")
    end
end

-- winningRoll is the top counted roll of the last round in a sorted roll log.
local function winningRoll(log)
    local best
    for _, r in ipairs(log) do
        if not r.note and (not best or r.round > best.round) then best = r end
    end
    return best
end

-- showRollLog fills the roll pane with the rolls of a recorded award.
local function showRollLog(record)
    local log = record.rollLog
    local count = log and table.getn(log) or 0
    rollOffset = math.max(0, math.min(rollOffset, count - MAX_ACTIVE))
    rollHeading:SetText(count > MAX_ACTIVE and string.format("ROLLS FOR AWARD #%d  (%d, SCROLL)", record.id, count)
        or string.format("ROLLS FOR AWARD #%d", record.id))
    local winner = log and winningRoll(log)
    for i = 1, MAX_ACTIVE do
        local row, r = rows[i], log and log[i + rollOffset]
        row.item = nil
        row.logName = r and r.name
        if r then
            local text = r.name
            if r.round > 1 then text = text .. "  (tie-break " .. (r.round - 1) .. ")" end
            if r.note then
                text = "|cff777777" .. text .. "  - ignored: " .. r.note .. "|r"
                row.count:SetTextColor(0.45, 0.45, 0.45)
            elseif r == winner then
                text = text .. "  - won"
                row.count:SetTextColor(0.45, 0.85, 0.55)
            else
                row.count:SetTextColor(1.00, 0.79, 0.31)
            end
            -- Spec and the tally the ranking used (logs from before 1.2 have neither).
            if r.kind and not r.note then
                text = text .. "  (" .. rollLabel(r) .. ", " .. itemCount(r.tally or 0) .. ")"
            end
            row:SetText(text)
            row.count:SetText(tostring(r.value))
            row:SetBackdropColor(0.045, 0.09, 0.13, 0.98)
            row:Show()
        else
            row:Hide()
        end
    end
    if count == 0 then
        emptyRolls:SetText(log and "Awarded without a /rnd roll" or "Rolls were not recorded\nfor this older award")
        emptyRolls:Show()
    else
        emptyRolls:Hide()
    end
end

local function updateRows()
    if editing then
        showRollLog(editing)
        updateSelection()
        updateRoster()
        updateHistory()
        return
    end
    rollHeading:SetText("MASTER LOOT ITEMS")
    emptyRolls:SetText(EMPTY_ACTIVE)
    local activeCount = 0
    for i = 1, MAX_ACTIVE do
        local entry = active[i]
        local row = rows[i]
        if entry then
            activeCount = activeCount + 1
            row.item = entry
            row.logName = nil
            row:SetText(string.format("%s", entry.item))
            row.count:SetText(string.format("%d ROLLS", activeRollCount(entry)))
            row.count:SetTextColor(1.00, 0.79, 0.31)
            local isSelected = selected == entry
            row:SetBackdropColor(isSelected and 0.10 or 0.045, isSelected and 0.21 or 0.09, isSelected and 0.29 or 0.13, 0.98)
            row:Show()
        else
            row.item = nil
            row:Hide()
        end
    end
    if activeCount == 0 then emptyRolls:Show() else emptyRolls:Hide() end
    updateSelection()
    updateRoster()
    updateHistory()
end

for i = 1, MAX_ACTIVE do
    local row = CreateFrame("Button", "ForgeLootLedgerRow" .. i, rollPane)
    row:SetPoint("TOPLEFT", rollPane, "TOPLEFT", 10, -29 - (i - 1) * 18)
    row:SetWidth(316)
    row:SetHeight(17)
    makeBackdrop(row, 0.045, 0.09, 0.13, 0.98)
    -- 3.3.5a Buttons have no SetTextColor/SetJustifyH/SetTextInsets: use a
    -- FontString anchored with the same 7px/50px insets.
    local rowText = label(row, "GameFontNormalSmall", nil, {0.82, 0.91, 0.96})
    rowText:SetPoint("LEFT", row, "LEFT", 7, 0)
    rowText:SetPoint("RIGHT", row, "RIGHT", -50, 0)
    rowText:SetJustifyH("LEFT")
    rowText:SetWordWrap(false)
    row:SetFontString(rowText)
    row.count = label(row, "GameFontNormalSmall", 9, {1.00, 0.79, 0.31})
    row.count:SetPoint("RIGHT", row, "RIGHT", -7, 0)
    row:SetScript("OnClick", function(self)
        if not self.item then return end   -- a roll-log line
        selected = self.item
        editing = nil
        recipientBox:SetText(selected and selected.winner and selected.winner.name or "")
        updateRows()
    end)
    rows[i] = row
end

for _, line in ipairs(historyLines) do
    line:SetScript("OnClick", function(self)
        if not self.record then return end
        editing = (editing ~= self.record) and self.record or nil
        selected = nil
        rollOffset = 0
        recipientBox:SetText(editing and editing.recipient or "")
        updateRows()
    end)
end

historyPane:SetScript("OnMouseWheel", function(_, delta)
    historyOffset = historyOffset - delta
    updateHistory()
end)

-- Tooltips: items show their real item tooltip; players show what they got
-- this raid, so fairness calls need no extra window.
local function showItemTooltip(owner, link)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    local itemString = type(link) == "string" and string.match(link, "item:[%-%d:]+")
    if itemString then GameTooltip:SetHyperlink(itemString) else GameTooltip:ClearLines() end
end

local function addPlayerLines(name)
    GameTooltip:AddLine(summaryLine(name), 0.45, 0.85, 1.00)
    for _, record in ipairs(ensureDatabase().history) do
        if record.state ~= "deleted" and lower(record.recipient) == lower(name) then
            GameTooltip:AddLine("  " .. record.item .. (record.spec and ("  " .. string.upper(record.spec)) or "")
                .. (record.token and "  (token)" or ""))
        end
    end
end

local function hideTooltip() GameTooltip:Hide() end

for _, row in ipairs(rows) do
    row:SetScript("OnEnter", function(self)
        if self.item then
            showItemTooltip(self, self.item.item)
        elseif self.logName then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.logName)
            addPlayerLines(self.logName)
        else
            return
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", hideTooltip)
end

for _, line in ipairs(historyLines) do
    line:SetScript("OnEnter", function(self)
        local record = self.record
        if not record then return end
        showItemTooltip(self, record.item)
        GameTooltip:AddLine(string.format("Award #%d: %s (%s)", record.id, record.recipient,
            stateLabels[record.state] or record.state or ""), 1, 1, 1)
        if record.roll then
            GameTooltip:AddLine(string.format("Roll %d, %s", record.roll, record.spec and rollLabel({
                kind = record.spec, low = record.low, high = record.high }) or "spec unknown"), 0.8, 0.8, 0.8)
        end
        addPlayerLines(record.recipient)
        GameTooltip:Show()
    end)
    line:SetScript("OnLeave", hideTooltip)
end

for _, button in ipairs(rosterButtons) do
    button:SetScript("OnEnter", function(self)
        if not self.fullName then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.fullName)
        addPlayerLines(self.fullName)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", hideTooltip)
end

rollPane:SetScript("OnMouseWheel", function(_, delta)
    if not editing then return end
    rollOffset = rollOffset - delta
    updateRows()
end)

-- The loot source identifies a corpse or chest across reopened loot windows:
-- the dead target's GUID, else the latest creature death (chests have no unit).
local function ensureWindowSource()
    if windowKey then return end
    windowCount = windowCount + 1
    local guid
    if UnitExists("target") and UnitIsDead("target") and not UnitIsPlayer("target") then guid = UnitGUID("target") end
    if guid then
        windowKey, windowNpc = guid, npcFromGUID(guid)
    elseif lastKill then
        windowKey, windowNpc = "kill:" .. lastKill.guid, lastKill.npc
    else
        windowKey, windowNpc = "window:" .. windowCount, nil
    end
end

local function addMasterLootItem(slot)
    local item = GetLootSlotLink(slot)
    if not item or item == "" then return end
    -- Only items at or above the group's loot threshold are worth a roll.
    local _, _, _, quality = GetLootSlotInfo(slot)
    local threshold = GetLootThreshold()
    if quality and threshold and quality < threshold then return end
    ensureWindowSource()
    -- Capture each source slot once, so an awarded item is not re-added by the
    -- periodic re-scan or by reopening the same corpse.
    local key = windowKey .. ":" .. slot .. ":" .. item
    local entry = drops[key]
    if entry then
        if not lootSlots[slot] then lootSlots[slot] = { entry = entry, link = item } end
        return
    end
    entry = { slot = slot, item = item, npc = windowNpc, rolls = {} }
    drops[key] = entry
    lootSlots[slot] = { entry = entry, link = item }
    table.insert(active, 1, entry)
    while table.getn(active) > MAX_ACTIVE do table.remove(active) end
    -- New loot needs attention: leave the roll log of an old award.
    if editing then
        editing = nil
        recipientBox:SetText("")
    end
    if not selectedEntry() then selected = entry end
    updateRows()
end

local function captureMasterLoot()
    local count = GetNumLootItems() or 0
    for slot = 1, count do addMasterLootItem(slot) end
end

-- onGiveMasterLoot runs after every master-loot handout, from this ledger or
-- from the default master-loot menu, and records the real recipient.
local function onGiveMasterLoot(slot, candidate)
    local name = GetMasterLootCandidate(candidate)
    local info = lootSlots[slot]
    local link = (info and info.link) or GetLootSlotLink(slot)
    if not name or not link then return end
    local entry = info and info.entry or { item = link, npc = windowNpc, rolls = {} }
    local record = entry.record
    if record then
        -- Recorded by hand before the handout: the handout is the truth.
        record.recipient = field(name)
        record.state = isPlayer(name) and "held" or "given"
        record.confirmed = false
        publish(record)
    else
        record = recordAward(entry, name, "given", false)
    end
    status:SetText(string.format("Gave #%d to %s; waiting for the loot message.", record.id, name))
    updateRows()
end
hooksecurefunc("GiveMasterLoot", onGiveMasterLoot)

-- onLootMessage confirms a handout once the server's loot line arrives.
local function onLootMessage(message)
    patterns.lootOther = patterns.lootOther or patternFromFormat(LOOT_ITEM)
    patterns.lootSelf = patterns.lootSelf or patternFromFormat(LOOT_ITEM_SELF)
    local name, link
    if patterns.lootOther then name, link = string.match(message or "", patterns.lootOther) end
    if not name and patterns.lootSelf then
        link = string.match(message or "", patterns.lootSelf)
        name = link and playerName()
    end
    local itemID = itemIDFromLink(link)
    if not itemID then return end
    for _, record in ipairs(ensureDatabase().history) do
        if not record.confirmed and record.state ~= "deleted" and record.itemID == itemID
            and lower(record.recipient) == lower(name) then
            record.confirmed = true
            publish(record)
            status:SetText(string.format("Award #%d confirmed: %s received the item.", record.id, record.recipient))
            announceAward(record)
            updateHistory()
            return
        end
    end
end

-- Trades: items the master looter kept ("held") move to the trade partner once
-- the trade completes. Trades between other players are not visible here.
local function tradeItems()
    local items = {}
    for slot = 1, 6 do
        local itemID = itemIDFromLink(GetTradePlayerItemLink(slot))
        if itemID then table.insert(items, itemID) end
    end
    return items
end

local function snapshotTrade()
    if not trade or trade.closedAt then return end
    trade.partner = trade.partner or UnitName("NPC")
    trade.items = tradeItems()
end

-- The items offered when the player accepts are what the trade hands over: any
-- later change unaccepts the trade. On completion the slots empty (live run
-- 1445c70cd623), so the last slot snapshot alone can miss the traded item.
hooksecurefunc("AcceptTrade", function()
    if not trade or trade.closedAt then return end
    trade.partner = trade.partner or UnitName("NPC")
    trade.accepted = tradeItems()
end)

local function rememberTrade(partner, offered, result)
    ensureDatabase().lastTrade = { partner = partner or "-", offered = offered, result = result, at = time() }
end

local function applyTrade(partner, itemIDs)
    local history, moved, used = ensureDatabase().history, {}, {}
    for _, itemID in ipairs(itemIDs) do
        for i = table.getn(history), 1, -1 do   -- oldest held copy first
            local record = history[i]
            if not used[i] and record.state == "held" and record.itemID == itemID and isPlayer(record.recipient) then
                used[i] = true
                record.recipient, record.state, record.confirmed = field(partner), "given", true
                publish(record)
                table.insert(moved, record)
                break
            end
        end
    end
    return moved
end

local function onTradeComplete()
    if not trade then
        rememberTrade(nil, 0, "no trade window seen")
        return
    end
    local items = trade.accepted or trade.items
    if not trade.partner or (trade.closedAt and GetTime() - trade.closedAt > TRADE_GRACE) then
        rememberTrade(trade.partner, table.getn(items), trade.partner and "too late" or "no partner")
        trade = nil
        return
    end
    local moved = applyTrade(trade.partner, items)
    rememberTrade(trade.partner, table.getn(items), "moved " .. table.getn(moved))
    trade = nil
    for _, record in ipairs(moved) do
        say(string.format("trade recorded: #%d %s -> %s", record.id, record.item, record.recipient))
        announceAward(record, "traded")
    end
    if table.getn(moved) > 0 then updateRows() end
end

local function onInfoMessage(...)
    -- 3.3.5a passes only the message; later clients pass a message type first.
    local message = select(select("#", ...), ...)
    if message == ERR_TRADE_COMPLETE then
        onTradeComplete()
    elseif message == ERR_TRADE_CANCELLED then
        if trade then rememberTrade(trade.partner, table.getn(trade.items), "cancelled") end
        trade = nil
    end
end

-- setRecipient corrects an award by hand, e.g. when someone else held a unique
-- item for a moment and traded it on to the winner. Without a name the
-- current player target is used.
local function setRecipient(id, name)
    local record = findRecord(id)
    if not record then
        say("no award #" .. tostring(id) .. ".")
        return false
    end
    name = trim(name)
    if name == "" then
        if not UnitExists("target") or not UnitIsPlayer("target") then
            say("give a name or target the recipient.")
            return false
        end
        name = UnitName("target")
    end
    record.recipient = field(name)
    record.state = isPlayer(name) and "held" or "manual"
    record.confirmed = true
    record.roll = nil
    publish(record)
    status:SetText(string.format("Award #%d now goes to %s.", record.id, record.recipient))
    announceAward(record, "corrected")
    updateRows()
    return true
end

local function deleteRecord(id)
    local record = findRecord(id)
    if not record or record.state == "deleted" then
        say("no award #" .. tostring(id) .. ".")
        return
    end
    record.state = "deleted"
    publish(record)
    if editing == record then editing = nil end
    status:SetText(string.format("Award #%d removed; the export keeps it as deleted.", record.id))
    updateRows()
end

-- Receiving the shared ledger -------------------------------------------------
local STATES = { given = true, held = true, manual = true, deleted = true }
local NOTE_NAMES = { r = "re-roll", t = "not in tie-break" }
local warnedSession

local function split(text)
    local fields = {}
    for value in string.gmatch(text .. ";", "([^;]*);") do table.insert(fields, value) end
    return fields
end

local function inGroup(name)
    local key = lower(name)
    if GetNumRaidMembers() and GetNumRaidMembers() > 0 then
        for i = 1, GetNumRaidMembers() do
            if lower(GetRaidRosterInfo(i)) == key then return true end
        end
        return false
    end
    for i = 1, GetNumPartyMembers() do
        if lower(UnitName("party" .. i)) == key then return true end
    end
    return false
end

local function findShared(origin, id)
    for _, record in ipairs(ensureDatabase().history) do
        if record.id == id and lower(record.origin or playerName()) == lower(origin) then return record end
    end
end

-- acceptSession decides whether a message about raid `session` belongs in
-- this ledger. A ledger without awards of its own follows the sender's raid
-- (also after a NEW RAID there); one with its own awards keeps its raid.
local function acceptSession(session, sender)
    local db = ensureDatabase()
    if session == "" then return false end
    if session == db.session then return true end
    for _, record in ipairs(db.history) do
        if lower(record.origin or playerName()) == lower(playerName()) then
            if warnedSession ~= session then
                warnedSession = session
                say(string.format("%s shares another raid's ledger; yours has its own awards, so it is not "
                    .. "merged. Use CLEAR to follow theirs.", sender))
            end
            return false
        end
    end
    db.history, db.session, db.startedAt = {}, session, nil
    return true
end

local function applyRecord(f, sender)
    local id, rev = tonumber(f[4]), tonumber(f[5])
    if not id or not rev or f[3] == "" or table.getn(f) < 19 or not acceptSession(f[2], sender) then return end
    local db = ensureDatabase()
    local record = findShared(f[3], id)
    if record and (record.rev or 0) >= rev then return end
    local at = tonumber(f[6]) or 0
    if not record then
        record = { id = id, origin = f[3] }
        local position = table.getn(db.history) + 1
        for i, other in ipairs(db.history) do
            if (other.at or 0) < at then position = i break end
        end
        table.insert(db.history, position, record)
    end
    local itemID = tonumber(f[7])
    record.rev, record.at, record.itemID, record.npc = rev, at, itemID, tonumber(f[8])
    record.item = (itemID and select(2, GetItemInfo(itemID))) or record.item or ("item:" .. (itemID or 0))
    record.recipient, record.state, record.confirmed = f[9], STATES[f[10]] and f[10] or "manual", f[11] == "1"
    record.spec = (f[12] == "ms" or f[12] == "os") and f[12] or nil
    record.roll, record.low, record.high = tonumber(f[13]), tonumber(f[14]), tonumber(f[15])
    record.winner = f[16] ~= "" and f[16] or nil
    record.rolls, record.token = tonumber(f[17]) or 0, f[18] == "1" or nil
    record.time = f[19] ~= "" and f[19] or date("%H:%M", at)
    -- Our own awards coming back (after a crash): never reuse their numbers.
    if lower(f[3]) == lower(playerName()) then db.nextID = math.max(db.nextID, id) end
    db.startedAt = math.min(db.startedAt or at, at)
    updateRows()
end

local function applyLog(f, sender)
    local id, part, total = tonumber(f[4]), tonumber(f[5]), tonumber(f[6])
    if not (id and part and total) or total > 40 or not acceptSession(f[2], sender) then return end
    local record = findShared(f[3], id)
    if not record then return end
    record.logParts = record.logParts or {}
    record.logParts[part] = f[7] or ""
    for i = 1, total do
        if not record.logParts[i] then return end
    end
    local log = {}
    for i = 1, total do
        for entry in string.gmatch(record.logParts[i], "[^/]+") do
            local name, value, low, high, round, code, tally = string.match(entry,
                "^([^,]*),(%d+),(%d+),(%d+),(%d+),(%a?),(%d*)$")
            if name then
                low, high = tonumber(low), tonumber(high)
                table.insert(log, { name = name, value = tonumber(value), low = low, high = high,
                    round = tonumber(round), kind = code ~= "x" and rollKind(low, high) or nil,
                    note = code == "x" and (low .. "-" .. high) or NOTE_NAMES[code], tally = tonumber(tally) })
            end
        end
    end
    record.rollLog, record.logParts = log, nil
    updateRows()
end

-- answerSync sends our own awards, and the asker's (their backup), so a
-- master looter whose client crashed gets the ledger back.
local function answerSync(asker)
    for i = table.getn(ensureDatabase().history), 1, -1 do
        local record = ensureDatabase().history[i]
        local origin = lower(record.origin or playerName())
        if origin == lower(playerName()) or origin == lower(asker) then
            record.origin = record.origin or playerName()
            queue(encodeRecord(record))
            for _, message in ipairs(encodeLog(record)) do queue(message) end
        end
    end
end

local function requestSync()
    queue(table.concat({ "Q", ensureDatabase().session or "-", field(playerName()) }, ";"))
end

local function onAddonMessage(prefix, message, channel, sender)
    if prefix ~= SYNC_PREFIX or type(message) ~= "string" or not sender or isPlayer(sender) then return end
    if channel ~= "RAID" and channel ~= "PARTY" or not inGroup(sender) then return end
    local f = split(message)
    if f[1] == "A" then
        applyRecord(f, sender)
    elseif f[1] == "L" then
        applyLog(f, sender)
    elseif f[1] == "Q" and lower(f[3] or "") == lower(sender) then
        answerSync(sender)
    end
end

local panes = { rollPane, detailPane, historyPane }

local function refreshExport(focus)
    local db = ensureDatabase()
    if not db.raidID then
        exportText.generated = ""
        exportText:SetText("")
        status:SetText("Enter the website's raid ID to build the export.")
        return
    end
    exportText.generated = buildExport(db.raidID, playerName(), db.startedAt, time(), db.history)
    exportText:SetText(exportText.generated)
    if focus then
        exportText:SetFocus()
        exportText:HighlightText()
    end
    status:SetText("Export selected: press Ctrl+C and paste it into the raid website's loot import.")
end

local function showExport(show)
    for _, pane in ipairs(panes) do
        if show then pane:Hide() else pane:Show() end
    end
    if show then
        Ledger:Show()
        exportPanel:Show()
        local db = ensureDatabase()
        raidBox:SetText(db.raidID and tostring(db.raidID) or "")
        refreshExport(true)
    else
        exportText:ClearFocus()
        exportPanel:Hide()
        updateRows()
    end
end

local function setRaidID(value)
    local db = ensureDatabase()
    db.raidID = tonumber(value)
    if exportPanel:IsShown() then refreshExport() end
end

raidBox:SetScript("OnTextChanged", function(self)
    local value = tonumber(self:GetText())
    if value ~= ensureDatabase().raidID then setRaidID(value) end
end)
raidBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
raidBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
exportButton:SetScript("OnClick", function() showExport(not exportPanel:IsShown()) end)
backButton:SetScript("OnClick", function() showExport(false) end)

-- A new raid starts an empty ledger, so its loot is never exported under the
-- previous raid's ID. Award IDs keep counting up.
local function startNewRaid()
    local db = ensureDatabase()
    db.history = {}
    db.startedAt = nil
    db.raidID = nil
    db.session = nil   -- the next award starts a new shared ledger
    editing = nil
    historyOffset = 0
    raidBox:SetText("")
    if exportPanel:IsShown() then refreshExport() end
    say("new raid: the award ledger is empty.")
    updateRows()
end

StaticPopupDialogs["FORGELOOTLEDGER_NEW_RAID"] = {
    text = "Clear all recorded loot and start a new raid? Export it first.",
    button1 = YES,
    button2 = NO,
    OnAccept = function() startNewRaid() end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}
newRaidButton:SetScript("OnClick", function() StaticPopup_Show("FORGELOOTLEDGER_NEW_RAID") end)
clearButton:SetScript("OnClick", function() StaticPopup_Show("FORGELOOTLEDGER_NEW_RAID") end)

local function rollPattern()
    return patternFromFormat(RANDOM_ROLL_RESULT or "%s rolls %d (%d-%d)")
end

local function recordRoll(message)
    local name, roll, low, high = string.match(message or "", rollPattern())
    if not name or not roll then return end
    local entry = rollingEntry()
    if not entry then return end
    local value, lo, hi = tonumber(roll) or 0, tonumber(low), tonumber(high)
    local kind = rollKind(lo, hi)
    -- Ignored rolls are kept in the roll log with the reason, for disputes.
    local note
    if not kind then
        -- Only /rnd 100, /rnd 99 and enhanced main-spec ranges count; "/rnd 1000"
        -- would otherwise win.
        note = low .. "-" .. high
    elseif entry.tieBreak and not entry.tieBreak[name] then
        -- During a tie-break only the tied players may roll.
        note = "not in tie-break"
    else
        -- The first roll counts; re-rolls are ignored.
        for _, existing in ipairs(entry.rolls) do
            if existing.name == name then note = "re-roll" end
        end
    end
    entry.rollLog = entry.rollLog or {}
    table.insert(entry.rollLog, { name = name, value = value, round = entry.round or 1, note = note,
        kind = kind, low = lo, high = hi })
    if note then return end
    table.insert(entry.rolls, { name = name, value = value, kind = kind, low = lo, high = hi,
        tally = tallyOf(tallies(), name, kind) })
    table.sort(entry.rolls, ranksAbove)
    updateRows()
end

local function startSelectedRoll()
    local entry = selectedEntry()
    if not entry then
        status:SetText("Select a master-loot item before starting a roll.")
        return
    end
    entry.rolls = {}
    entry.rollLog = {}
    entry.round = 1
    entry.winner = nil
    entry.tieBreak = nil
    entry.endsAt = GetTime() + ROLL_SECONDS
    entry.startedAt = GetTime()
    entry.warned15 = false
    entry.warned5 = false
    announce("[Loot] " .. entry.item .. " - /rnd now! " .. ROLL_SECONDS .. " seconds. "
        .. "/rnd 100 main spec (points: 11-110 up to 51-150), /rnd 99 off spec.")
    status:SetText("30-second raid roll started.")
    updateRows()
end

local function joinNames(names)
    local count = table.getn(names)
    if count == 1 then return names[1] end
    return table.concat(names, ", ", 1, count - 1) .. " and " .. names[count]
end

-- Ends a roll: a single top roll wins; a shared top roll starts a tie-break in
-- which only the tied players roll again (and which can tie again).
local function finishRoll(entry)
    entry.endsAt = nil
    if activeRollCount(entry) == 0 then
        announce("[Loot] " .. entry.item .. " - no valid rolls.")
        return
    end
    -- Tallies may have changed during the roll (other awards): rank again.
    local counts = tallies()
    for _, roll in ipairs(entry.rolls) do roll.tally = tallyOf(counts, roll.name, roll.kind) end
    table.sort(entry.rolls, ranksAbove)
    local best = entry.rolls[1]
    local top = best.value
    local tied = {}
    for _, roll in ipairs(entry.rolls) do
        if roll.kind == best.kind and roll.tally == best.tally and roll.value == top then
            table.insert(tied, roll.name)
        end
    end
    if table.getn(tied) > 1 then
        table.sort(tied)
        entry.tieBreak = {}
        for _, name in ipairs(tied) do entry.tieBreak[name] = true end
        entry.rolls = {}
        entry.round = (entry.round or 1) + 1
        entry.endsAt = GetTime() + TIE_SECONDS
        entry.startedAt = GetTime()
        entry.warned15 = true
        entry.warned5 = false
        announce(string.format("[Loot] %s - tie between %s (%d)! %s: /rnd again, %d seconds.",
            entry.item, joinNames(tied), top, table.concat(tied, ", "), TIE_SECONDS))
        return
    end
    entry.winner = entry.rolls[1]
    entry.tieBreak = nil
    if selectedEntry() == entry and not editing then recipientBox:SetText(entry.winner.name) end
    announce(string.format("[Loot] %s won by %s (%d) - %s%s, %s so far.", entry.item, best.name, best.value,
        SPEC_NAMES[best.kind], best.low and best.low > 1 and (" " .. best.low .. "-" .. best.high) or "",
        itemCount(best.tally or 0)))
end

local function updateRollTimers()
    for _, entry in ipairs(active) do
        if entry.endsAt and not entry.winner then
            local remaining = entry.endsAt - GetTime()
            if remaining <= 0 then
                finishRoll(entry)
                updateRows()
            elseif remaining <= 5 and not entry.warned5 then
                entry.warned5 = true
                announce("[Loot] " .. entry.item .. " - 5 seconds left!")
            elseif remaining <= 15 and not entry.warned15 then
                entry.warned15 = true
                announce("[Loot] " .. entry.item .. " - 15 seconds left.")
            end
        end
    end
end

award:SetScript("OnClick", function()
    local recipient = trim(recipientBox:GetText())
    if editing then
        if recipient == "" then
            status:SetText("Enter the new recipient's name.")
            return
        end
        if setRecipient(editing.id, recipient) then
            editing = nil
            recipientBox:SetText("")
            updateRows()
        end
        return
    end
    local entry = selectedEntry()
    if not entry then
        status:SetText("Select a loot roll before recording an award.")
        return
    end
    if recipient == "" then
        status:SetText("Choose or enter a recipient name.")
        return
    end
    -- With the item still in the master-loot window, hand it out for real; the
    -- GiveMasterLoot hook then records the award.
    local slot = lootSlotOf(entry)
    if slot then
        local index = candidateIndex(recipient)
        if not index then
            status:SetText(recipient .. " cannot receive this item (not a master-loot candidate).")
            return
        end
        recipientBox:SetText("")
        GiveMasterLoot(slot, index)
        return
    end
    local record = recordAward(entry, recipient, "manual", true)
    announceAward(record)
    recipientBox:SetText("")
    status:SetText(string.format("Award #%d recorded for %s.", record.id, recipient))
    updateRows()
end)

Ledger:RegisterEvent("PLAYER_LOGIN")
Ledger:RegisterEvent("LOOT_OPENED")
Ledger:RegisterEvent("LOOT_READY")
Ledger:RegisterEvent("LOOT_CLOSED")
Ledger:RegisterEvent("CHAT_MSG_SYSTEM")
Ledger:RegisterEvent("CHAT_MSG_LOOT")
Ledger:RegisterEvent("RAID_ROSTER_UPDATE")
Ledger:RegisterEvent("PARTY_MEMBERS_CHANGED")
Ledger:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
Ledger:RegisterEvent("TRADE_SHOW")
Ledger:RegisterEvent("TRADE_PLAYER_ITEM_CHANGED")
Ledger:RegisterEvent("TRADE_ACCEPT_UPDATE")
Ledger:RegisterEvent("TRADE_CLOSED")
Ledger:RegisterEvent("UI_INFO_MESSAGE")
Ledger:RegisterEvent("CHAT_MSG_ADDON")
Ledger:SetScript("OnEvent", function(self, event, ...)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local _, subEvent, _, _, _, destGUID = ...
        if subEvent == "UNIT_DIED" then
            local npc = npcFromGUID(destGUID)
            if npc then lastKill = { guid = destGUID, npc = npc } end
        end
    elseif event == "PLAYER_LOGIN" then
        ensureDatabase()
        syncAt = GetTime() + 8
        updateRows()
        if ForgeTestBridge and ForgeTestBridge.RegisterFrame then
            ForgeTestBridge:RegisterFrame("ForgeLootLedgerFrame", self)
            ForgeTestBridge:RegisterFrame("ForgeLootLedgerItem", itemDetail)
            ForgeTestBridge:RegisterFrame("ForgeLootLedgerAward", award)
            ForgeTestBridge:RegisterFrame("ForgeLootLedgerHistory1", historyLines[1])
            ForgeTestBridge:RegisterFrame("ForgeLootLedgerExportButton", exportButton)
            ForgeTestBridge:RegisterFrame("ForgeLootLedgerExportText", exportText)
            ForgeTestBridge:RegisterFrame("ForgeLootLedgerRollHeading", rollHeading)
            for i = 1, 3 do ForgeTestBridge:RegisterFrame("ForgeLootLedgerRoll" .. i, rows[i]) end
        end
    elseif event == "LOOT_OPENED" or event == "LOOT_READY" then
        captureMasterLoot()
        updateRows()
    elseif event == "LOOT_CLOSED" then
        lootSlots = {}
        windowKey, windowNpc = nil, nil
        updateRows()
    elseif event == "CHAT_MSG_SYSTEM" then
        recordRoll(...)
    elseif event == "CHAT_MSG_LOOT" then
        onLootMessage(...)
    elseif event == "TRADE_SHOW" then
        trade = { partner = UnitName("NPC"), items = {} }
    elseif event == "TRADE_PLAYER_ITEM_CHANGED" or event == "TRADE_ACCEPT_UPDATE" then
        snapshotTrade()
    elseif event == "TRADE_CLOSED" then
        if trade and not trade.closedAt then trade.closedAt = GetTime() end
    elseif event == "UI_INFO_MESSAGE" then
        onInfoMessage(...)
    elseif event == "CHAT_MSG_ADDON" then
        onAddonMessage(...)
    else
        updateRoster()
    end
end)
-- Timers run on a separate, always-shown frame: WoW only fires OnUpdate for
-- visible frames, so hiding the ledger must not freeze a running roll.
local ticker = CreateFrame("Frame")
local tickElapsed = 0
ticker:SetScript("OnUpdate", function(_, elapsed)
    tickElapsed = tickElapsed + elapsed
    if tickElapsed >= 0.25 then
        tickElapsed = 0
        if LootFrame and LootFrame:IsShown() then captureMasterLoot() end
        updateRollTimers()
        -- Shared ledger: at most four addon messages per second.
        if outbox[1] then
            local channel = groupChannel()
            if channel then SendAddonMessage(SYNC_PREFIX, table.remove(outbox, 1), channel) else outbox = {} end
        end
        if syncAt and GetTime() >= syncAt then
            syncAt = nil
            if groupChannel() then requestSync() end
        end
    end
end)

local HELP = {
    "/forgeloot - show or hide the ledger",
    "/forgeloot start - start a 30 s /rnd roll for the selected item",
    "/forgeloot set <#> [name] - change the recipient of award #, or to your target",
    "/forgeloot del <#> - remove award # (exported as deleted)",
    "/forgeloot spec <#> ms|os|none - set which tally award # counts for",
    "/forgeloot tally - items per player this raid (main spec / off spec)",
    "/forgeloot raid <id> - set the website raid ID",
    "/forgeloot export - show the website export",
    "/forgeloot sync - ask the group's other ledgers for this raid's awards",
    "/forgeloot newraid (or CLEAR) - empty the award ledger for the next raid; add confirm to skip the question",
    "/forgeloot clear - drop all active rolls;  /forgeloot reset - recenter the window",
}

SLASH_FORGELOOT1 = "/forgeloot"
SlashCmdList["FORGELOOT"] = function(message)
    local command, rest = trim(message):match("^(%S*)%s*(.-)$")
    command = string.lower(command or "")
    if command == "reset" then
        Ledger:ClearAllPoints()
        Ledger:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
        Ledger:Show()
    elseif command == "clear" then
        active = {}
        selected = nil
        drops = {}
        lootSlots = {}
        updateRows()
    elseif command == "start" then
        startSelectedRoll()
    elseif command == "set" then
        local id, name = rest:match("^#?(%d+)%s*(.-)$")
        if id then setRecipient(tonumber(id), name) else say("usage: /forgeloot set <#> [name]") end
    elseif command == "del" then
        local id = rest:match("^#?(%d+)$")
        if id then deleteRecord(tonumber(id)) else say("usage: /forgeloot del <#>") end
    elseif command == "spec" then
        local id, spec = rest:match("^#?(%d+)%s+(%a+)$")
        spec = spec and string.lower(spec)
        local record = id and findRecord(tonumber(id))
        if not record or (spec ~= "ms" and spec ~= "os" and spec ~= "none") then
            say("usage: /forgeloot spec <#> ms|os|none")
        else
            record.spec = spec ~= "none" and spec or nil
            publish(record)
            say(string.format("award #%d counts for %s.", record.id, record.spec and SPEC_NAMES[record.spec] or "no tally"))
            updateRows()
        end
    elseif command == "sync" then
        if groupChannel() then
            requestSync()
            say("asked the group's ledgers for this raid's awards.")
        else
            say("not in a group: nothing to sync.")
        end
    elseif command == "tally" then
        local names, counts = {}, tallies()
        for _, record in ipairs(ensureDatabase().history) do
            local name = (record.state == "held" and record.winner) or record.recipient
            if counts[lower(name)] and not names[lower(name)] then
                names[lower(name)] = true
                table.insert(names, name)
            end
        end
        table.sort(names, function(a, b) return lower(a) < lower(b) end)
        if table.getn(names) == 0 then say("no items counted this raid yet.") end
        for _, name in ipairs(names) do
            say(string.format("%s: %d main spec, %d off spec", name, tallyOf(counts, name, "ms"), tallyOf(counts, name, "os")))
        end
    elseif command == "raid" then
        local id = rest:match("^(%d+)$")
        if id then
            setRaidID(id)
            raidBox:SetText(id)
            say("raid ID " .. id .. ".")
        else
            say("usage: /forgeloot raid <id>")
        end
    elseif command == "export" then
        showExport(true)
    elseif command == "newraid" then
        if string.lower(rest) == "confirm" then startNewRaid() else StaticPopup_Show("FORGELOOTLEDGER_NEW_RAID") end
    elseif command == "" or command == "toggle" then
        if Ledger:IsShown() then Ledger:Hide() else Ledger:Show() end
    else
        for _, line in ipairs(HELP) do say(line) end
    end
end

Ledger:Show()
