-- OnUpdate (client CSimpleTop::OnLayerUpdate over the visible frames).
test("a frame shown by another's OnUpdate starts on the next frame", function()
    local ran = {}
    local starter = CreateFrame("Frame", nil, UIParent)
    local late = CreateFrame("Frame", nil, UIParent)
    late:Hide()
    late:SetScript("OnUpdate", function(_, elapsed) table.insert(ran, elapsed) end)
    starter:SetScript("OnUpdate", function(self) late:Show(); self:SetScript("OnUpdate", nil) end)
    forge.advance(0.05)
    expect(#ran).toBe(0)
    forge.advance(0.05)
    expect(#ran).toBe(1)
end)

test("a frame hidden during the pass gets no OnUpdate in it", function()
    local ran = 0
    local hider = CreateFrame("Frame", nil, UIParent)
    local victim = CreateFrame("Frame", nil, UIParent)
    hider:SetScript("OnUpdate", function() victim:Hide() end)
    victim:SetScript("OnUpdate", function() ran = ran + 1 end)
    forge.advance(0.05)
    expect(ran).toBe(0)
end)
