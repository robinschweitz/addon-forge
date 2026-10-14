-- ForgeClock: WoW 3.3.5a / Lua 5.1. No ForgeTestBridge dependency.
local frame = CreateFrame("Frame", "ForgeClockFrame", UIParent)
frame:SetWidth(160)
frame:SetHeight(42)
frame:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
frame:SetFrameStrata("MEDIUM")
frame:EnableMouse(true)
frame:SetMovable(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

local background = frame:CreateTexture(nil, "BACKGROUND")
background:SetAllPoints(frame)
background:SetTexture(0, 0, 0, 0.70)

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
title:SetPoint("TOP", frame, "TOP", 0, -5)
title:SetText("ForgeClock")

local timeText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
timeText:SetPoint("CENTER", frame, "CENTER", 0, -6)
timeText:SetText("--:--:--")

local accumulator = 0
frame:SetScript("OnUpdate", function(self, elapsed)
    accumulator = accumulator + elapsed
    if accumulator < 0.25 then return end
    accumulator = 0
    local h, m = GetGameTime()
    local s = tonumber(date("%S")) or 0
    timeText:SetText(string.format("%02d:%02d:%02d", h or 0, m or 0, s))
end)

SLASH_FORGECLOCK1 = "/forgeclock"
SlashCmdList["FORGECLOCK"] = function(msg)
    local command = string.lower((msg or ""):match("^%s*(.-)%s*$"))
    if command == "show" then
        frame:Show()
    elseif command == "hide" then
        frame:Hide()
    elseif command == "" or command == "toggle" then
        if frame:IsShown() then frame:Hide() else frame:Show() end
    else
        DEFAULT_CHAT_FRAME:AddMessage("ForgeClock: /forgeclock [show|hide|toggle]")
    end
end
frame:Show()
