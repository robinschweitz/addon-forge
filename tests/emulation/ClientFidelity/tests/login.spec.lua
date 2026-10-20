-- Login, /reload and SavedVariables timing (client LoadAddOn,
-- FrameScript_LoadVariables, CGGameUI::InitializeFrameXML / Shutdown).
before_load(function()
    forge.setSaved("ClientFidelityDB", { runs = 1 })
end)

local function tail(log, n)
    local out = {}
    for i = #log - n + 1, #log do out[#out + 1] = log[i] end
    return out
end

test("SavedVariables are assigned after the files ran, before ADDON_LOADED", function()
    expect(ClientFidelityLog[1]).toBe("ADDON_LOADED:ClientFidelity:table")
    expect(ClientFidelityDB.runs).toBe(1)
end)

test("a SavedVariable with nothing saved keeps the value the addon's file assigned", function()
    expect(ClientFidelityKept).toEqual({ fromFile = true })
end)

test("login: VARIABLES_LOADED arrives after world entry", function()
    expect(ClientFidelityLog).toEqual({ "ADDON_LOADED:ClientFidelity:table", "PLAYER_LOGIN",
        "PLAYER_ENTERING_WORLD", "VARIABLES_LOADED" })
end)

test("reload: leaving the world, logout, then cached VARIABLES_LOADED before PLAYER_LOGIN", function()
    local before = ClientFidelityLog
    ClientFidelityKept = nil   -- saved as nil: the file's value comes back
    ClientFidelityDB.runs = 2
    forge.reload()
    expect(tail(before, 2)).toEqual({ "PLAYER_LEAVING_WORLD", "PLAYER_LOGOUT" })
    expect(ClientFidelityLog).toEqual({ "ADDON_LOADED:ClientFidelity:table", "VARIABLES_LOADED",
        "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD" })
    expect(ClientFidelityDB.runs).toBe(2)
    expect(ClientFidelityKept).toEqual({ fromFile = true })
end)
