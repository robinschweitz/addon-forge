-- HANDEL tab and trade log (FR-RL-032, raid feedback 2026-11-17): each
-- RaidLedger writes down the trades of raid loot it makes - who gave which
-- item to whom, and when - and shares them with everyone in the raid who runs
-- RaidLedger, so the raid lead also sees what a mate traded. The log only
-- records: it never changes an award, a tally or an open item (FR-RL-003).
-- Only items in the current raid's ledger count, and only trades with a
-- raid member. The client shows only the player's own side of a trade, so a
-- ledger logs the items it gives; the partner's ledger logs the other side.
--
-- Shared as "X;session;receiver;itemID;at". The giver is the message's
-- sender (never a payload field), so nobody can log a trade for someone else.
local _, ns = ...
local L = ns.L
local core, ui = ns.core, ns.ui
local MAX_TRADES = 200
local TRADE_GRACE = 5   -- seconds a closed trade window may still report "Trade complete."

local trade               -- { partner, items, accepted, closedAt } of the open or just closed trade
local tradeOffset = 0
local contentHeight = ns.CONTENT_HEIGHT

local function db() return ns.ensureDatabase() end
local function lower(name) return ns.lower(name or "") end

local function trades()
    local d = db()
    d.trades = d.trades or {}
    return d.trades
end

local function inRaid(name)
    for _, member in ipairs(ns.members()) do
        if lower(member.name) == lower(name) then return member.name end
    end
end

-- isRaidLoot: the item is in the current raid's ledger (an award, an open or
-- a parked item) or in the loot list.
local function isRaidLoot(itemID)
    for _, record in ipairs(core.history()) do
        if record.itemID == itemID and record.state ~= "deleted" then return true end
    end
    for _, entry in ipairs(core.active()) do
        if core.itemIDFromLink(entry.item) == itemID then return true end
    end
    return false
end

local function itemLink(itemID)
    return (select(2, GetItemInfo(itemID))) or ("item:" .. itemID)
end

-- addTrade stores one entry unless the same one is already there.
local function addTrade(giver, receiver, itemID, at)
    local list = trades()
    for _, t in ipairs(list) do
        if lower(t.giver) == lower(giver) and lower(t.receiver) == lower(receiver) and t.itemID == itemID and t.at == at then
            return false
        end
    end
    local position = table.getn(list) + 1
    for i, t in ipairs(list) do
        if (t.at or 0) < at then position = i break end
    end
    table.insert(list, position, { giver = giver, receiver = receiver, itemID = itemID, item = itemLink(itemID), at = at })
    while table.getn(list) > MAX_TRADES do table.remove(list) end
    return true
end

local function tradeItems()
    local items = {}
    for slot = 1, 6 do
        local itemID = core.itemIDFromLink(GetTradePlayerItemLink(slot))
        if itemID then table.insert(items, itemID) end
    end
    return items
end

local function snapshot()
    if not trade or trade.closedAt then return end
    trade.partner = trade.partner or UnitName("NPC")
    trade.items = tradeItems()
end

-- The items offered when the player accepts are what the trade hands over:
-- any later change unaccepts it, and on completion the slots empty.
hooksecurefunc("AcceptTrade", function()
    if not trade or trade.closedAt then return end
    trade.partner = trade.partner or UnitName("NPC")
    trade.accepted = tradeItems()
end)

local function onTradeComplete()
    local done = trade
    trade = nil
    if not done or not done.partner or (done.closedAt and GetTime() - done.closedAt > TRADE_GRACE) then return end
    local receiver = inRaid(done.partner)
    if not receiver then return end
    local giver = ns.playerName()
    local session = db().session
    local logged = 0
    for _, itemID in ipairs(done.accepted or done.items or {}) do
        if isRaidLoot(itemID) then
            local at = time()
            if addTrade(giver, receiver, itemID, at) then
                logged = logged + 1
                if session then ns.queue(table.concat({ "X", session, ns.field(receiver), itemID, at }, ";")) end
            end
        end
    end
    if logged > 0 then ui.refresh() end
end

-- ns.applyTrade takes a mate's trade: "X;session;receiver;itemID;at" from
-- `sender`, who is the giver. Only for the current raid; malformed lines drop.
function ns.applyTrade(f, sender)
    local session = db().session
    if not session or f[2] ~= session or table.getn(f) ~= 5 then return end
    local receiver = f[3] or ""
    -- A character name: letters only (UTF-8 bytes for umlauts), 2-24 bytes.
    if string.find(receiver, "[^A-Za-z\128-\255]") or string.len(receiver) < 2 or string.len(receiver) > 24 then return end
    local itemID, at = tonumber(f[4]), tonumber(f[5])
    if not itemID or itemID < 1 or itemID > 999999 or itemID ~= math.floor(itemID) then return end
    if not at or at < 0 or at ~= math.floor(at) then return end
    if addTrade(sender, receiver, itemID, at) then ui.refresh() end
end

local events = CreateFrame("Frame")
for _, event in ipairs({ "TRADE_SHOW", "TRADE_PLAYER_ITEM_CHANGED", "TRADE_ACCEPT_UPDATE", "TRADE_CLOSED", "UI_INFO_MESSAGE" }) do
    events:RegisterEvent(event)
end
events:SetScript("OnEvent", function(_, event, message)
    if event == "TRADE_SHOW" then
        trade = { partner = UnitName("NPC"), items = {} }
    elseif event == "TRADE_PLAYER_ITEM_CHANGED" or event == "TRADE_ACCEPT_UPDATE" then
        snapshot()
    elseif event == "TRADE_CLOSED" then
        if trade and not trade.closedAt then trade.closedAt = GetTime() end
    elseif message == ERR_TRADE_COMPLETE then
        onTradeComplete()
    elseif message == ERR_TRADE_CANCELLED then
        trade = nil
    end
end)

---------------------------------------------------------------------------
-- HANDEL tab: the raid's trades, newest first
---------------------------------------------------------------------------
local panel = CreateFrame("Frame", "RaidLedgerTradesTab")
local list = ns.pane(panel, 0, 0, nil, nil, "RaidLedgerTradePane")
local emptyText = ns.label(list, "GameFontNormalSmall", 11, {0.42, 0.61, 0.70})
emptyText:SetPoint("LEFT", list, "LEFT", 16, 0)
emptyText:SetPoint("RIGHT", list, "RIGHT", -16, 0)
emptyText:SetText(L["No trades of raid loot yet. Every RaidLedger in the raid shares the trades it makes."])

local rows = ns.rowList(function(i)
    local row = ns.listRow(list, 0, { 40 }, "RaidLedgerTradeRow" .. i)
    row:SetPoint("TOPLEFT", list, "TOPLEFT", 10, -30 - (i - 1) * ns.ROW_HEIGHT)
    row:SetPoint("RIGHT", list, "RIGHT", -10, 0)
    row:SetScript("OnEnter", function(self)
        if not self.trade then return end
        ns.itemTooltip(self, self.trade.item)
        GameTooltip:AddLine(string.format(L["%s gave it to %s at %s."], self.trade.giver, self.trade.receiver,
            date("%H:%M", self.trade.at)), 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- Rows are made when the tab is first drawn: register the first for live plans then.
    if i == 1 and ForgeTestBridge and ForgeTestBridge.RegisterFrame then
        ForgeTestBridge:RegisterFrame("RaidLedgerTradeRow1", row)
    end
    return row
end)

ns.onResize(function(_, height) contentHeight = height end)

local function draw()
    local list_ = trades()
    local count = table.getn(list_)
    tradeOffset = math.max(0, math.min(tradeOffset, count - table.getn(rows)))
    list.heading:SetText(count > table.getn(rows) and string.format(L["TRADES OF THIS RAID (%d, SCROLL)"], count)
        or string.format(L["TRADES OF THIS RAID (%d)"], count))
    if count == 0 then emptyText:Show() else emptyText:Hide() end
    for i, row in ipairs(rows) do
        local t = list_[i + tradeOffset]
        row.trade = t
        if t then
            row:SetText(string.format("%s -> %s  %s", t.giver, t.receiver, t.item or itemLink(t.itemID)))
            row.columns[1]:SetText(date("%H:%M", t.at))
            ns.highlight(row, nil)
            row:Show()
        else
            row:Hide()
        end
    end
end

local function refresh()
    rows.fit(ns.rowsFit(contentHeight, 30, 16))
    draw()
end

local tab = ns.addTab("trades", function() return string.format(L["TRADES (%d)"], table.getn(trades())) end, panel,
    refresh, "RaidLedgerTabButtonTrades")
ns.tip(tab.button, L["Who traded which raid loot to whom: yours and your raid mates' trades (it changes no award)"])
ns.scrollable(list, function() return tradeOffset end, function(v) tradeOffset = v end, draw)
