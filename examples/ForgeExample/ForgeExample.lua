local frame = CreateFrame("Frame", "ForgeExampleFrame", UIParent)
frame:SetWidth(200)
frame:SetHeight(30)
frame:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
frame:Show()

local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
label:SetAllPoints(frame)
label:SetText("Addon Forge 3.3.5a")

SLASH_FORGEEXAMPLE1 = "/forgeexample"
SlashCmdList["FORGEEXAMPLE"] = function()
    if frame:IsShown() then frame:Hide() else frame:Show() end
end

-- Optional test registration; bridge remains development-only.
if ForgeTestBridge then
    ForgeTestBridge:RegisterTest("smoke", "example_frame_visible", function()
        ForgeTestBridge:Assert(frame:IsShown(), "Example frame is not visible")
        ForgeTestBridge:Assert(frame:GetWidth() == 200, "Unexpected frame width")
    end)
end
