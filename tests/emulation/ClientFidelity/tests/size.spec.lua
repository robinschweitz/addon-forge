-- Frame size, scale and user resizing (client CLayoutFrame::SetWidth/Resize/
-- OnFrameResize, CSimpleFrame::OnFrameSizeChanged, Script_StartMoving/
-- StartSizing, CSimpleTop::StartMoveOrResizeFrame).

local function window(name)
    local f = CreateFrame("Frame", name, UIParent)
    f:SetWidth(400)
    f:SetHeight(300)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    return f
end

test("StartMoving and StartSizing need SetMovable and SetResizable", function()
    local f = window("CFSizeLocked")
    local ok, err = pcall(f.StartMoving, f)
    expect(ok).toBeFalsy()
    expect(err).toContain("Frame CFSizeLocked is not movable")
    ok, err = pcall(f.StartSizing, f)
    expect(ok).toBeFalsy()
    expect(err).toContain("Frame CFSizeLocked is not resizable")
    f:SetMovable(true)
    f:SetResizable(true)
    expect(pcall(f.StartSizing, f)).toBe(true)
    f:StopMovingOrSizing()
end)

test("OnSizeChanged runs on the next frame with the new size, only when it changed", function()
    local f = window("CFSizeEvents")
    local calls = {}
    f:SetScript("OnSizeChanged", function(_, w, h) calls[#calls + 1] = { w, h } end)
    forge.advance(0.05)
    expect(#calls).toBe(1)                     -- the first layout resolves the rect
    expect(calls[1][1]).toBe(400)
    f:SetWidth(500)
    expect(#calls).toBe(1)                     -- deferred to the layout pass
    forge.advance(0.05)
    expect(#calls).toBe(2)
    expect(calls[2][1]).toBe(500)
    expect(calls[2][2]).toBe(300)
    f:SetWidth(500)
    forge.advance(0.05)
    expect(#calls).toBe(2)
end)

test("a frame sized by two anchors reports that size and follows its parent", function()
    local f = window("CFSizeParent")
    local inner = CreateFrame("Frame", nil, f)
    inner:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -10)
    inner:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 10)
    local seen
    inner:SetScript("OnSizeChanged", function(_, w, h) seen = { w, h } end)
    expect(inner:GetWidth()).toBe(380)
    expect(inner:GetHeight()).toBe(280)
    forge.advance(0.05)
    f:SetHeight(400)
    forge.advance(0.05)
    expect(seen[2]).toBe(380)
end)

test("dragging a resize grip sizes the frame within its limits", function()
    local f = window("CFSizeGrip")
    f:SetResizable(true)
    f:SetMinResize(300, 200)
    f:SetMaxResize(600, 500)
    local grip = CreateFrame("Button", "CFSizeGripButton", f)
    grip:SetWidth(16)
    grip:SetHeight(16)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() f:StopMovingOrSizing() end)
    local top, left = forge.rect(f).top, forge.rect(f).left
    forge.drag(grip, 100, -50)                 -- right and down
    expect(f:GetWidth()).toBe(500)
    expect(f:GetHeight()).toBe(350)
    expect(forge.rect(f).top).toBe(top)         -- the opposite corner stays put
    expect(forge.rect(f).left).toBe(left)
    forge.drag(grip, 1000, -1000)
    expect(f:GetWidth()).toBe(600)
    expect(f:GetHeight()).toBe(500)
    forge.drag(grip, -1000, 1000)
    expect(f:GetWidth()).toBe(300)
    expect(f:GetHeight()).toBe(200)
end)

test("a drag without StartMoving or StartSizing changes nothing", function()
    local f = window("CFSizeIdle")
    local before = forge.rect(f)
    forge.drag(f, 50, 50)
    expect(forge.rect(f).left).toBe(before.left)
    expect(f:GetWidth()).toBe(400)
end)

test("dragging a movable frame moves it", function()
    local f = window("CFSizeMove")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    local before = forge.rect(f)
    forge.drag(f, 30, -20)
    expect(forge.rect(f).left).toBe(before.left + 30)
    expect(forge.rect(f).top).toBe(before.top - 20)
    expect(f:GetWidth()).toBe(400)
end)

test("SetScale scales the frame and its children on screen, not their own sizes", function()
    local f = window("CFSizeScale")
    local child = CreateFrame("Frame", nil, f)
    child:SetWidth(100)
    child:SetHeight(50)
    child:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -20)
    f:SetScale(0.5)
    expect(f:GetEffectiveScale()).toBe(0.5)
    expect(child:GetEffectiveScale()).toBe(0.5)
    expect(forge.rect(f).width).toBe(200)
    expect(forge.rect(child).width).toBe(50)
    expect(forge.rect(child).left - forge.rect(f).left).toBe(10)
    expect(f:GetWidth()).toBe(400)
    expect(child:GetWidth()).toBe(100)
    local seen
    f:SetScript("OnSizeChanged", function(_, w, h) seen = { w, h } end)
    forge.advance(0.05)
    f:SetScale(1.5)                            -- a new scale lays the frame out again
    seen = nil
    forge.advance(0.05)
    expect(seen and seen[1]).toBe(400)
end)

test("a scaled window that leaves the screen is a layout issue", function()
    local f = window("CFSizeBig")
    f:SetWidth(1000)
    f:SetHeight(600)
    local function sticksOut()
        for _, issue in ipairs(forge.layoutIssues(UIParent)) do
            if string.find(issue, "CFSizeBig sticks out", 1, true) then return true end
        end
        return false
    end
    expect(sticksOut()).toBe(false)
    f:SetScale(1.5)
    expect(sticksOut()).toBe(true)
end)
