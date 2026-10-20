-- CSimpleScrollFrame recalculates its range during the next layer update and
-- keeps offsets outside that range.
test("ScrollFrame defers range calculation and does not clamp offsets", function()
    local ranges, offsets = {}, {}
    local scroll = CreateFrame("ScrollFrame", "ClientFidelityScroll", UIParent)
    scroll:SetSize(100, 100)
    scroll:SetScript("OnScrollRangeChanged", function(_, x, y) table.insert(ranges, { x, y }) end)
    scroll:SetScript("OnVerticalScroll", function(_, offset) table.insert(offsets, offset) end)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(100, 300)
    scroll:SetScrollChild(child)
    expect(scroll:GetVerticalScrollRange()).toBe(0)
    forge.advance(0.05)
    expect(scroll:GetVerticalScrollRange()).toBe(200)
    expect(ranges).toEqual({ { 0, 200 } })
    scroll:SetVerticalScroll(500)
    expect(scroll:GetVerticalScroll()).toBe(500)
    expect(offsets).toEqual({ 500 })
end)
