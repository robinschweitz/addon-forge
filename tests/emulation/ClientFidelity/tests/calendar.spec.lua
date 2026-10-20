-- Calendar (client Calendar_Scripts, CGCalendar::Invite/AddEvent,
-- CGCalendarEvent::Invite): throttles, the pending server action, the creator
-- as the first invite.
local log = {}

test("a new event starts with the creator invited", function()
    local f = CreateFrame("Frame")
    for _, e in ipairs({ "CALENDAR_UPDATE_ERROR", "CALENDAR_ACTION_PENDING", "CALENDAR_UPDATE_INVITE_LIST",
        "CALENDAR_NEW_EVENT", "CALENDAR_UPDATE_EVENT_LIST" }) do
        f:RegisterEvent(e)
    end
    f:SetScript("OnEvent", function(_, event, a1) table.insert(log, event .. ":" .. tostring(a1)) end)
    CalendarNewEvent()
    expect(CalendarEventGetNumInvites()).toBe(1)
end)

test("invites resolve on the server, one at a time and at most every 2 seconds", function()
    forge.calendarPlayers({ "Tank", "Healer" })
    log = {}
    CalendarEventInvite("tank")             -- the client fixes the name's case
    CalendarEventInvite("Healer")           -- refused silently: the first is pending
    expect(log).toEqual({ "CALENDAR_ACTION_PENDING:true" })
    forge.advance(0.05)
    expect(CalendarEventGetNumInvites()).toBe(2)
    log = {}
    CalendarEventInvite("Healer")           -- less than 2 seconds after the first
    expect(log[1]).toBe("CALENDAR_UPDATE_ERROR:You are inviting too many players too quickly.")
    forge.advance(2)
    CalendarEventInvite("Healer")
    forge.advance(0.05)
    expect(CalendarEventGetNumInvites()).toBe(3)
    forge.advance(2)
    log = {}
    CalendarEventInvite("Tank")
    expect(log[1]).toBe("CALENDAR_UPDATE_ERROR:Tank has already been invited.")
    forge.advance(2)
    log = {}
    CalendarEventInvite("Nobody")
    forge.advance(0.05)
    expect(log[2]).toBe("CALENDAR_UPDATE_ERROR:Player not found.")
    expect(CalendarEventGetNumInvites()).toBe(3)
end)

test("an added event appears in the calendar; a second within 5 seconds is refused", function()
    local b = CreateFrame("Button", "ClientFidelityAddEvent", UIParent)
    b:SetScript("OnClick", function() CalendarAddEvent() end)
    CalendarEventSetTitle("Raid")
    CalendarEventSetDate(8, 7, 2010)
    CalendarEventSetTime(20, 0)
    CalendarEventSetType(CALENDAR_EVENTTYPE_RAID)
    forge.hardwareClick(b)
    forge.advance(0.05)
    CalendarSetAbsMonth(8, 2010)
    expect(CalendarGetNumDayEvents(0, 7)).toBe(1)
    local title, hour, minute, calendarType, _, eventType = CalendarGetDayEvent(0, 7, 1)
    expect(title).toBe("Raid")
    expect(hour).toBe(20)
    expect(calendarType).toBe("PLAYER")
    expect(eventType).toBe(1)
    expect(select("#", CalendarGetDayEvent(0, 8, 1))).toBe(15)
    log = {}
    forge.hardwareClick(b)
    expect(log[1]).toBe("CALENDAR_UPDATE_ERROR:You are creating events too quickly.")
end)

test("CalendarSetAbsMonth updates the list at once", function()
    log = {}
    CalendarSetAbsMonth(9, 2010)
    expect(log).toEqual({ "CALENDAR_UPDATE_EVENT_LIST:nil" })
end)
