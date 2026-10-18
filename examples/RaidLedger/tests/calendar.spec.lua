-- Raider feedback 2026-10-18: "Kalender-Invite auch über das Addon abdecken".
-- The website's invite list carries the raid's date and start time;
-- CALENDAR EVENT creates the raid event and invites everyone on the list.
local DATED = "RS2;INV;42;ICC 25 Mittwoch;25;2026-10-21;20:00\n"
    .. "Tester;HEAL;Paladin;0\nTank;TANK;Krieger;0\nHealer;HEAL;Priester;0\nStandby;DD;Jäger;1"
local calls
local serverDown = false   -- the server drops added events

local function chatHas(text)
    for _, line in ipairs(forge.chat()) do
        if line == "RaidLedger: " .. text then return true end
    end
    return false
end

before_load(function()
    -- The calendar API is not emulated offline; this stand-in records the calls
    -- in order. The real client is today 2026-10-18 19:30 realm time.
    calls = {}
    local function record(name)
        forge.stub(name, function(...) table.insert(calls, { name, ... }) end)
    end
    for _, name in ipairs({ "CalendarCloseEvent", "CalendarNewEvent", "CalendarEventSetType", "CalendarEventSetTitle",
        "CalendarEventSetDescription", "CalendarEventSetDate", "CalendarEventSetTime" }) do
        record(name)
    end
    -- The server's calendar: an added event shows up once OpenCalendar asked for it.
    local added, served, month, year = {}, {}, nil, nil
    forge.stub("CalendarAddEvent", function()
        table.insert(calls, { "CalendarAddEvent" })
        local title, date, time = {}, {}, {}
        for _, call in ipairs(calls) do
            if call[1] == "CalendarEventSetTitle" then title = call[2] end
            if call[1] == "CalendarEventSetDate" then date = { call[2], call[3], call[4] } end
            if call[1] == "CalendarEventSetTime" then time = { call[2], call[3] } end
        end
        if not serverDown then table.insert(added, { title = title, month = date[1], day = date[2], year = date[3], hour = time[1], minute = time[2] }) end
    end)
    forge.stub("OpenCalendar", function()
        served = {}
        for _, e in ipairs(added) do table.insert(served, e) end
        forge.fire("CALENDAR_UPDATE_EVENT_LIST")
    end)
    -- Like the client (live run 08455f4dff39), setting the month fires
    -- CALENDAR_UPDATE_EVENT_LIST at once: reading the list on that event recursed.
    forge.stub("CalendarSetAbsMonth", function(m, y)
        month, year = m, y
        forge.fire("CALENDAR_UPDATE_EVENT_LIST")
    end)
    local function dayEvents(day)
        local list = {}
        for _, e in ipairs(served) do
            if e.month == month and e.year == year and e.day == day then table.insert(list, e) end
        end
        return list
    end
    forge.stub("CalendarGetNumDayEvents", function(offset, day) return offset == 0 and table.getn(dayEvents(day)) or 0 end)
    forge.stub("CalendarGetDayEvent", function(_, day, index)
        local e = dayEvents(day)[index]
        if e then return e.title, e.hour, e.minute end
    end)
    -- Invites of a new event are listed only once the server has answered
    -- (a moment later); names the server does not know are never listed.
    local listed, pending = 0, {}
    forge.stub("CalendarNewEvent", function() table.insert(calls, { "CalendarNewEvent" }); listed, pending = 1, {} end)
    forge.stub("CalendarEventInvite", function(name)
        table.insert(calls, { "CalendarEventInvite", name })
        if name ~= "Nobodyhere" then table.insert(pending, forge.time() + 0.5) end
    end)
    forge.stub("CalendarEventGetNumInvites", function()
        local answered = 0
        for _, at in ipairs(pending) do if forge.time() >= at then answered = answered + 1 end end
        return listed + answered          -- the creator is listed from the start
    end)
    forge.stub("CALENDAR_EVENTTYPE_RAID", 1)
    forge.stub("CalendarGetDate", function() return 1, 10, 18, 2026 end)
    forge.gameTime(19, 30)
end)

local function called(name)
    local list = {}
    for _, call in ipairs(calls) do
        if call[1] == name then table.insert(list, call) end
    end
    return list
end

test("an invite list without a date reads as before but makes no event", function()
    forge.click("RaidLedgerRaidButton")
    forge.type("RaidLedgerInviteText", "RS2;INV;41;Naxx;10\nTank;TANK;Krieger;0")
    forge.clickText("READ")
    expect(chatHas("1 characters read for raid #41.")).toBe(true)
    forge.clickText("CALENDAR EVENT")
    expect(chatHas("This invite list has no date: export it again on the website.")).toBe(true)
    expect(table.getn(calls)).toBe(0)
end)

test("a bad date in the list is refused", function()
    forge.type("RaidLedgerInviteText", "RS2;INV;42;ICC;25;21.10.2026;20:00\nTank;TANK;Krieger;0")
    forge.clickText("READ")
    expect(chatHas("The invite list's date or time is not valid (YYYY-MM-DD;HH:MM).")).toBe(true)
end)

test("CALENDAR EVENT creates the raid event and invites everyone but the creator", function()
    forge.type("RaidLedgerInviteText", DATED)
    forge.clickText("READ")
    forge.clickText("CALENDAR EVENT")
    expect(chatHas("Creating the calendar event: inviting 3 characters...")).toBe(true)
    forge.clickText("CALENDAR EVENT")
    expect(chatHas("The calendar event is still being created.")).toBe(true)
    expect(table.getn(called("CalendarAddEvent"))).toBe(0)    -- not before the server listed the invites
    forge.advance(3, 0.1)
    -- The client adds events only from a real click: the button asks for it.
    expect(table.getn(called("CalendarAddEvent"))).toBe(0)
    expect(chatHas("3 invites ready: click CREATE EVENT (or /ledger calendar again) to add the event.")).toBe(true)
    expect(forge.findText("CREATE EVENT (3)")).toBeTruthy()
    forge.clickText("CREATE EVENT (3)")
    forge.advance(2, 0.1)
    expect(forge.findText("CALENDAR EVENT")).toBeTruthy()
    expect(called("CalendarNewEvent")[1]).toBeTruthy()
    expect(called("CalendarEventSetType")[1][2]).toBe(1)
    expect(called("CalendarEventSetTitle")[1][2]).toBe("ICC 25 Mittwoch")
    expect(called("CalendarEventSetDate")[1]).toEqual({ "CalendarEventSetDate", 10, 21, 2026 })
    expect(called("CalendarEventSetTime")[1]).toEqual({ "CalendarEventSetTime", 20, 0 })
    local names = {}
    for _, call in ipairs(called("CalendarEventInvite")) do table.insert(names, call[2]) end
    expect(names).toEqual({ "Tank", "Healer", "Standby" })      -- the bench too; not Tester himself
    expect(calls[table.getn(calls)][1]).toBe("CalendarAddEvent")   -- invites go out with the event
    expect(chatHas("Calendar event \"ICC 25 Mittwoch\" on 21.10. 20:00 created with 3 invites.")).toBe(true)
    expect(chatHas("The calendar event is in the calendar: confirmed by the server.")).toBe(true)
    local saved = forge.saved("RaidLedgerDB").setup.calendar
    expect(saved).toEqual({ raid = 42, title = "ICC 25 Mittwoch", confirmed = true, invites = 3 })
    expect(forge.layoutIssues("RaidLedgerFrame")).toEqual({})
end)

test("a name the server does not know is reported; the event is still added", function()
    calls = {}
    forge.type("RaidLedgerInviteText", DATED .. "\nNobodyhere;DD;Magier;0")
    forge.clickText("READ")
    forge.slash("/ledger calendar")
    forge.advance(3, 0.1)
    expect(forge.findText("CALENDAR EVENT")).toBeTruthy()    -- still waiting for the last answer
    forge.advance(6, 0.1)
    expect(forge.findText("CREATE EVENT (3)")).toBeTruthy()
    forge.slash("/ledger calendar")                           -- the slash command adds it too
    expect(table.getn(called("CalendarAddEvent"))).toBe(1)
    expect(chatHas("Calendar event \"ICC 25 Mittwoch\" on 21.10. 20:00 created with 3 invites.")).toBe(true)
    expect(chatHas("1 characters could not be invited (not found?).")).toBe(true)
end)

test("an event the server never lists is reported as not confirmed", function()
    serverDown = true
    forge.slash("/ledger calendar")
    forge.advance(8, 0.2)
    forge.slash("/ledger calendar")
    forge.advance(30, 0.2)
    expect(chatHas("The calendar event did not show up in the calendar; check it with the calendar button.")).toBe(true)
    expect(forge.saved("RaidLedgerDB").setup.calendar.confirmed).toBe(false)
    serverDown = false
end)

test("a raid that already started is refused", function()
    calls = {}
    forge.gameTime(20, 0)
    forge.stub("CalendarGetDate", function() return 4, 10, 21, 2026 end)
    forge.slash("/ledger calendar")
    expect(chatHas("The raid on 21.10.2026 20:00 is already over; the calendar only takes future events.")).toBe(true)
    expect(table.getn(called("CalendarAddEvent"))).toBe(0)
end)

test("a long title is cut to the calendar's 31 bytes without breaking an umlaut", function()
    calls = {}
    forge.stub("CalendarGetDate", function() return 1, 10, 18, 2026 end)
    forge.gameTime(12, 0)
    forge.type("RaidLedgerInviteText", "RS2;INV;43;Eiskronenzitadelle 25 Heroischöö;25;2026-10-22;19:45\nTank;TANK;Krieger;0")
    forge.clickText("READ")
    forge.slash("/ledger calendar")
    forge.advance(8, 0.1)
    forge.slash("/ledger calendar")
    local title = called("CalendarEventSetTitle")[1][2]
    expect(title).toBe("Eiskronenzitadelle 25 Heroisch")   -- byte 31 would be half an ö
    expect(string.len(title) <= 31).toBe(true)
end)

test("clicking anywhere in the invite field focuses it for pasting", function()
    local field = RaidLedgerInviteText
    field:ClearFocus()
    local back = field:GetParent():GetParent()
    back:GetScript("OnMouseDown")(back, "LeftButton")
    expect(field:HasFocus()).toBeTruthy()
end)
