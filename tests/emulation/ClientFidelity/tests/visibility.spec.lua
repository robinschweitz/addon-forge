-- OnShow/OnHide follow visibility (client CSimpleFrame::ShowThis/HideThis,
-- SetParent).
local log = {}
local function watch(frame, name)
    frame:SetScript("OnShow", function() table.insert(log, name .. ":show") end)
    frame:SetScript("OnHide", function() table.insert(log, name .. ":hide") end)
    return frame
end

test("Show under a hidden parent runs no OnShow; the parent's Show runs the child's first", function()
    local parent = watch(CreateFrame("Frame", nil, UIParent), "parent")
    parent:Hide()
    local child = watch(CreateFrame("Frame", nil, parent), "child")
    child:Hide()
    log = {}
    child:Show()
    expect(log).toEqual({})
    expect(child:IsShown()).toBe(true)
    expect(child:IsVisible()).toBe(false)
    parent:Show()
    expect(log).toEqual({ "child:show", "parent:show" })
end)

test("hiding a parent hides its shown children first; hidden children stay quiet", function()
    local parent = watch(CreateFrame("Frame", nil, UIParent), "parent")
    watch(CreateFrame("Frame", nil, parent), "shownChild")
    watch(CreateFrame("Frame", nil, parent), "hiddenChild"):Hide()
    log = {}
    parent:Hide()
    expect(log).toEqual({ "shownChild:hide", "parent:hide" })
    log = {}
    parent:Hide()
    expect(log).toEqual({})
end)

test("re-parenting a visible frame hides and shows it", function()
    local a = CreateFrame("Frame", nil, UIParent)
    local b = CreateFrame("Frame", nil, UIParent)
    local hidden = CreateFrame("Frame", nil, UIParent)
    hidden:Hide()
    local child = watch(CreateFrame("Frame", nil, a), "child")
    log = {}
    child:SetParent(b)
    expect(log).toEqual({ "child:hide", "child:show" })
    log = {}
    child:SetParent(hidden)
    expect(log).toEqual({ "child:hide" })
end)
