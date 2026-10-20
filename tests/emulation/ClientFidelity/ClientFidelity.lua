-- Records what the emulated client does, so the specs in tests/ can compare
-- it with the 3.3.5a client's behaviour (see docs/agent-playbook.md).
ClientFidelityKept = { fromFile = true }
ClientFidelityLog = {}

local events = CreateFrame("Frame", "ClientFidelityEvents")
for _, event in ipairs({ "ADDON_LOADED", "VARIABLES_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD",
    "PLAYER_LEAVING_WORLD", "PLAYER_LOGOUT", "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }) do
    events:RegisterEvent(event)
end
events:SetScript("OnEvent", function(_, event, a1, a2)
    if event == "ADDON_LOADED" then
        table.insert(ClientFidelityLog, event .. ":" .. tostring(a1) .. ":" .. type(ClientFidelityDB))
    elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
        table.insert(ClientFidelityLog, event .. ":" .. tostring(a1) .. ":" .. tostring(a2))
    else
        table.insert(ClientFidelityLog, event)
    end
end)
