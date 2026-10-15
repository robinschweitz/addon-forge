-- The bridge's SDK report contract, checked offline before any client run.
test("RunJSON returns a complete v3 report with frames, chat, events and watched values", function()
    local frame = CreateFrame("Frame", "ProbeWindow", UIParent)
    local label = frame:CreateFontString(nil, "OVERLAY")
    label:SetText("Ready")
    ForgeTestBridge:RegisterFrame("ProbeWindow", frame)
    ForgeTestBridge:RegisterFrame("ProbeLabel", label)
    ProbeDB = { history = { { item = "Abyssal Crest" } } }
    DEFAULT_CHAT_FRAME:AddMessage("ProbeAddon: loaded")
    forge.fire("LOOT_OPENED")

    local encoded = ForgeTestBridge:RunJSON("smoke", "abc123", { "ProbeDB.history.1.item", "ProbeDB.history" })
    expect(encoded).toContain('"completed":true')
    expect(encoded).toContain('"schemaVersion":3')
    expect(encoded).toContain('"bridgeVersion":3')
    expect(encoded).toContain('"name":"bridge_loaded"')
    expect(encoded).toContain('"status":"passed"')
    expect(string.find(encoded, '"error":"nil"', 1, true)).toBeNil()
    expect(encoded).toContain('"ProbeWindow":{')
    expect(encoded).toContain('"text":"Ready"')
    expect(encoded).toContain('"ProbeAddon: loaded"')
    expect(encoded).toContain('"LOOT_OPENED":1')
    expect(encoded).toContain('"ProbeDB.history.1.item":"Abyssal Crest"')
    expect(encoded).toContain('"ProbeDB.history":"<table>"')
end)

test("RunJSON rejects unsafe suite names", function()
    expect(ForgeTestBridge:RunJSON("smoke; x", "1")).toContain('"completed":false')
end)

test("Read never calls functions and refuses odd paths", function()
    ProbeFn = function() error("must not be called") end
    expect(ForgeTestBridge:Read("ProbeFn")).toBe("<function>")
    expect(ForgeTestBridge:Read("Probe[1]")).toBeNil()
end)

test("repeated handler errors are stored once with a count", function()
    local handler = geterrorhandler()
    for _ = 1, 500 do handler("ChatFrame.lua:3330: Usage: ChatFrame1EditBox:SetText(\"text\")") end
    handler("Core.lua:9: different")
    local encoded = ForgeTestBridge:RunJSON("smoke", "dedupe1", {})
    local _, copies = string.gsub(encoded, "ChatFrame.lua:3330", "")
    expect(copies).toBe(2)   -- once in errors, once as the errorCounts key
    expect(encoded).toContain(':500')
    expect(encoded).toContain("Core.lua:9: different")
end)
