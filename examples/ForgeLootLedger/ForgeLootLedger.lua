-- ForgeLootLedger: raid roll and manual award tracking for WoW 3.3.5a / Lua 5.1.
local addonName = ...
local Ledger = CreateFrame("Frame", "ForgeLootLedgerFrame", UIParent)
local MAX_HISTORY = 80
local MAX_ACTIVE = 10
local ROLL_SECONDS = 30
local TIE_SECONDS = 15

local active = {}
local selected          -- the selected entry table (not an index: inserts shift indices)
local seenInLoot = {}   -- slot+link already captured from the open loot window
local rows = {}

local function trim(value)
    return (value or ""):match("^%s*(.-)%s*$")
end

local function ensureDatabase()
    ForgeLootLedgerDB = ForgeLootLedgerDB or {}
    ForgeLootLedgerDB.history = ForgeLootLedgerDB.history or {}
end

local function addHistory(item, recipient, rolls)
    ensureDatabase()
    table.insert(ForgeLootLedgerDB.history, 1, {
        item = item or "Unknown item",
        recipient = recipient or "Unknown recipient",
        rolls = rolls or 0,
        time = date("%H:%M"),
    })
    while table.getn(ForgeLootLedgerDB.history) > MAX_HISTORY do
        table.remove(ForgeLootLedgerDB.history)
    end
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

local rollPane = CreateFrame("Frame", nil, Ledger)
rollPane:SetPoint("TOPLEFT", Ledger, "TOPLEFT", 16, -68)
rollPane:SetWidth(336)
rollPane:SetHeight(228)
makeBackdrop(rollPane, 0.035, 0.070, 0.105, 0.97)

local rollHeading = label(rollPane, "GameFontNormal", 11, {1.00, 0.80, 0.32})
rollHeading:SetPoint("TOPLEFT", rollPane, "TOPLEFT", 12, -11)
rollHeading:SetText("MASTER LOOT ITEMS")

local emptyRolls = label(rollPane, "GameFontNormalSmall", 11, {0.42, 0.61, 0.70})
emptyRolls:SetPoint("CENTER", rollPane, "CENTER", 0, 10)
emptyRolls:SetText("Open the master loot window\nPlayers can then use /rnd")
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

local historyPane = CreateFrame("Frame", nil, Ledger)
historyPane:SetPoint("TOPLEFT", Ledger, "TOPLEFT", 16, -306)
historyPane:SetWidth(568)
historyPane:SetHeight(94)
makeBackdrop(historyPane, 0.025, 0.052, 0.078, 0.97)

local historyHeading = label(historyPane, "GameFontNormal", 11, {1.00, 0.80, 0.32})
historyHeading:SetPoint("TOPLEFT", historyPane, "TOPLEFT", 12, -10)
historyHeading:SetText("RECENT AWARDS")

local historyLines = {}
for i = 1, 4 do
    local line = label(historyPane, "GameFontNormalSmall", 10, {0.72, 0.82, 0.88})
    line:SetPoint("TOPLEFT", historyPane, "TOPLEFT", 13, -27 - (i - 1) * 15)
    line:SetPoint("TOPRIGHT", historyPane, "TOPRIGHT", -13, -27 - (i - 1) * 15)
    line:SetJustifyH("LEFT")
    line:SetWordWrap(false)
    historyLines[i] = line
end

local status = label(Ledger, "GameFontNormalSmall", 10, {0.42, 0.60, 0.68})
status:SetPoint("BOTTOMLEFT", Ledger, "BOTTOMLEFT", 18, 12)
status:SetPoint("BOTTOMRIGHT", Ledger, "BOTTOMRIGHT", -18, 12)
status:SetJustifyH("LEFT")
status:SetWordWrap(false)
status:SetText("ROLL RESULTS ARE CAPTURED FROM SYSTEM CHAT  |  /forgeloot: toggle, reset, clear")

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
    ensureDatabase()
    for i = 1, 4 do
        local entry = ForgeLootLedgerDB.history[i]
        if entry then
            historyLines[i]:SetText(string.format("%s  |  %s  ->  %s  (%d rolls)", entry.time, entry.item, entry.recipient, entry.rolls))
        else
            historyLines[i]:SetText(i == 1 and "No awards recorded in this ledger." or "")
        end
    end
end

local function updateSelection()
    local entry = selectedEntry()
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

local function updateRows()
    local activeCount = 0
    for i = 1, MAX_ACTIVE do
        local entry = active[i]
        local row = rows[i]
        if entry then
            activeCount = activeCount + 1
            row.item = entry
            row:SetText(string.format("%s", entry.item))
            row.count:SetText(string.format("%d ROLLS", activeRollCount(entry)))
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
    local row = CreateFrame("Button", nil, rollPane)
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
        selected = self.item
        updateRows()
    end)
    rows[i] = row
end

local function addMasterLootItem(slot)
    local item = GetLootSlotLink(slot)
    if not item or item == "" then return end
    -- Capture each slot once per open loot window, so an item that was already
    -- awarded is not re-added by the periodic re-scan while the window stays open.
    local key = slot .. ":" .. item
    if seenInLoot[key] then return end
    seenInLoot[key] = true
    local entry = { slot = slot, item = item, rolls = {} }
    table.insert(active, 1, entry)
    while table.getn(active) > MAX_ACTIVE do table.remove(active) end
    if not selectedEntry() then selected = entry end
    updateRows()
end

local function captureMasterLoot()
    local count = GetNumLootItems() or 0
    for slot = 1, count do addMasterLootItem(slot) end
end

local function rollPattern()
    local format = RANDOM_ROLL_RESULT or "%s rolls %d (%d-%d)"
    -- Localized clients use positional specifiers ("%1$s" on deDE); "%1" would
    -- otherwise become an invalid back-reference in the Lua pattern.
    format = format:gsub("%%%d+%$", "%%")
    format = format:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    format = format:gsub("%%s", "(.-)")
    format = format:gsub("%%d", "(%%d+)")
    return "^" .. format .. "$"
end

local function recordRoll(message)
    local name, roll, low, high = string.match(message or "", rollPattern())
    if not name or not roll then return end
    -- Only a standard /rnd (1-100) counts; "/rnd 1000" would otherwise win.
    if tonumber(low) ~= 1 or tonumber(high) ~= 100 then return end
    local entry = rollingEntry()
    if not entry then return end
    -- During a tie-break only the tied players may roll.
    if entry.tieBreak and not entry.tieBreak[name] then return end
    local value = tonumber(roll) or 0
    -- The first roll counts; re-rolls are ignored.
    for _, existing in ipairs(entry.rolls) do
        if existing.name == name then return end
    end
    table.insert(entry.rolls, { name = name, value = value })
    table.sort(entry.rolls, function(left, right) return left.value > right.value end)
    updateRows()
end

local function announce(text)
    if GetNumRaidMembers() and GetNumRaidMembers() > 0 then
        SendChatMessage(text, "RAID")
    elseif GetNumPartyMembers() and GetNumPartyMembers() > 0 then
        SendChatMessage(text, "PARTY")
    else
        DEFAULT_CHAT_FRAME:AddMessage("ForgeLootLedger: " .. text)
    end
end

local function startSelectedRoll()
    local entry = selectedEntry()
    if not entry then
        status:SetText("Select a master-loot item before starting a roll.")
        return
    end
    entry.rolls = {}
    entry.winner = nil
    entry.tieBreak = nil
    entry.endsAt = GetTime() + ROLL_SECONDS
    entry.startedAt = GetTime()
    entry.warned15 = false
    entry.warned5 = false
    announce("[Loot] " .. entry.item .. " - /rnd now! " .. ROLL_SECONDS .. " seconds.")
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
    local top = entry.rolls[1].value
    local tied = {}
    for _, roll in ipairs(entry.rolls) do
        if roll.value == top then table.insert(tied, roll.name) end
    end
    if table.getn(tied) > 1 then
        table.sort(tied)
        entry.tieBreak = {}
        for _, name in ipairs(tied) do entry.tieBreak[name] = true end
        entry.rolls = {}
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
    if selectedEntry() == entry then recipientBox:SetText(entry.winner.name) end
    announce("[Loot] " .. entry.item .. " won by " .. entry.winner.name .. " (" .. entry.winner.value .. ").")
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
    local entry = selectedEntry()
    local recipient = trim(recipientBox:GetText())
    if not entry then
        status:SetText("Select a loot roll before recording an award.")
        return
    end
    if recipient == "" then
        status:SetText("Choose or enter a recipient name.")
        return
    end
    addHistory(entry.item, recipient, activeRollCount(entry))
    for index = table.getn(active), 1, -1 do
        if active[index] == entry then table.remove(active, index) end
    end
    selected = nil
    recipientBox:SetText("")
    status:SetText("Award recorded for " .. recipient .. ".")
    updateRows()
end)

Ledger:RegisterEvent("PLAYER_LOGIN")
Ledger:RegisterEvent("LOOT_OPENED")
Ledger:RegisterEvent("LOOT_READY")
Ledger:RegisterEvent("LOOT_CLOSED")
Ledger:RegisterEvent("CHAT_MSG_SYSTEM")
Ledger:RegisterEvent("RAID_ROSTER_UPDATE")
Ledger:RegisterEvent("PARTY_MEMBERS_CHANGED")
Ledger:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        ensureDatabase()
        updateRows()
        if ForgeTestBridge and ForgeTestBridge.RegisterFrame then
            ForgeTestBridge:RegisterFrame("ForgeLootLedgerFrame", self)
            ForgeTestBridge:RegisterFrame("ForgeLootLedgerItem", itemDetail)
            ForgeTestBridge:RegisterFrame("ForgeLootLedgerAward", award)
            ForgeTestBridge:RegisterFrame("ForgeLootLedgerHistory1", historyLines[1])
        end
    elseif event == "LOOT_OPENED" or event == "LOOT_READY" then
        captureMasterLoot()
    elseif event == "LOOT_CLOSED" then
        seenInLoot = {}
    elseif event == "CHAT_MSG_SYSTEM" then
        recordRoll(...)
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
    end
end)

SLASH_FORGELOOT1 = "/forgeloot"
SlashCmdList["FORGELOOT"] = function(message)
    local command = string.lower(trim(message))
    if command == "reset" then
        Ledger:ClearAllPoints()
        Ledger:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
        Ledger:Show()
    elseif command == "clear" then
        active = {}
        selected = nil
        seenInLoot = {}
        updateRows()
    elseif command == "start" then
        startSelectedRoll()
    elseif command == "" or command == "toggle" then
        if Ledger:IsShown() then Ledger:Hide() else Ledger:Show() end
    else
        DEFAULT_CHAT_FRAME:AddMessage("ForgeLootLedger: /forgeloot [toggle|start|reset|clear]")
    end
end

Ledger:Show()
