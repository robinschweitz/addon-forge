-- Event dispatch (client FrameScript_SignalEvent and the deferred
-- register/unregister lists).
test("a frame unregistered during the dispatch misses the rest of it", function()
    local got = {}
    local first = CreateFrame("Frame")
    local second = CreateFrame("Frame")
    first:RegisterEvent("PLAYER_TARGET_CHANGED")
    second:RegisterEvent("PLAYER_TARGET_CHANGED")
    first:SetScript("OnEvent", function()
        table.insert(got, "first")
        second:UnregisterEvent("PLAYER_TARGET_CHANGED")
    end)
    second:SetScript("OnEvent", function() table.insert(got, "second") end)
    forge.fire("PLAYER_TARGET_CHANGED")
    expect(got).toEqual({ "first" })
end)

test("a frame registered during the dispatch hears the next signal only", function()
    local got = {}
    local first = CreateFrame("Frame")
    local late = CreateFrame("Frame")
    first:RegisterEvent("PLAYER_FOCUS_CHANGED")
    first:SetScript("OnEvent", function() late:RegisterEvent("PLAYER_FOCUS_CHANGED") end)
    late:SetScript("OnEvent", function() table.insert(got, "late") end)
    forge.fire("PLAYER_FOCUS_CHANGED")
    expect(got).toEqual({})
    forge.fire("PLAYER_FOCUS_CHANGED")
    expect(got).toEqual({ "late" })
end)

test("listeners run in registration order", function()
    local got = {}
    for i = 1, 3 do
        local f = CreateFrame("Frame")
        f:RegisterEvent("UPDATE_FACTION")
        f:SetScript("OnEvent", function() table.insert(got, i) end)
    end
    forge.fire("UPDATE_FACTION")
    expect(got).toEqual({ 1, 2, 3 })
end)
