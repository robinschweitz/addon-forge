-- Protected actions (client CGGameUI::CanPerformAction, CGGameUI::Target,
-- CGGameUI::Reload; the hardware flag set around a real OnClick or Enter).
local function lastLog() return ClientFidelityLog[#ClientFidelityLog] end

test("a hardware-event function refuses an SDK-style click and works on a real one", function()
    local b = CreateFrame("Button", "ClientFidelityCalendar", UIParent)
    CalendarNewEvent()
    b:SetScript("OnClick", function() CalendarAddEvent() end)
    forge.click(b)
    expect(lastLog()).toBe("ADDON_ACTION_BLOCKED:ClientFidelity:CalendarAddEvent()")
    expect(#forge.protectedCalls()).toBe(0)
    forge.hardwareClick(b)
    expect(forge.protectedCalls()[1].name).toBe("CalendarAddEvent")
end)

test("timers are no hardware event", function()
    local t = CreateFrame("Frame", nil, UIParent)
    t:SetScript("OnUpdate", function(self) self:SetScript("OnUpdate", nil); AcceptTrade() end)
    forge.advance(0.05)
    expect(lastLog()).toBe("ADDON_ACTION_BLOCKED:ClientFidelity:AcceptTrade()")
end)

test("Enter in an edit box is a hardware event", function()
    local box = CreateFrame("EditBox", "ClientFidelityEnter", UIParent)
    box:SetScript("OnEnterPressed", function() CalendarUpdateEvent() end)
    local before = #forge.protectedCalls()
    forge.press(box, "ENTER")
    expect(#forge.protectedCalls()).toBe(before + 1)
end)

test("TargetUnit is forbidden to addons even on a click", function()
    local b = CreateFrame("Button", "ClientFidelityTarget", UIParent)
    b:SetScript("OnClick", function() TargetUnit("Partner") end)
    forge.hardwareClick(b)
    expect(lastLog()).toBe("ADDON_ACTION_FORBIDDEN:ClientFidelity:TargetUnit()")
end)

test("raid group changes are refused in combat only", function()
    forge.combat(true)
    SetRaidSubgroup(2, 3)
    expect(lastLog()).toBe("ADDON_ACTION_BLOCKED:ClientFidelity:SetRaidSubgroup()")
    forge.combat(false)
    local before = #forge.protectedCalls()
    SetRaidSubgroup(2, 3)
    expect(#forge.protectedCalls()).toBe(before + 1)
end)

test("ReloadUI needs a hardware event and reloads on the next frame", function()
    SLASH_CLIENTFIDELITY1 = "/cfreload"
    SlashCmdList.CLIENTFIDELITY = function() ReloadUI() end
    forge.slash("/cfreload")
    expect(lastLog()).toBe("ADDON_ACTION_BLOCKED:ClientFidelity:ReloadUI()")
    forge.slash("/cfreload", { hardware = true })
    local before = ClientFidelityLog
    forge.advance(0.05)
    expect(before[#before]).toBe("PLAYER_LOGOUT")
    expect(ClientFidelityLog[1]).toMatch("^ADDON_LOADED:ClientFidelity:")
end)
