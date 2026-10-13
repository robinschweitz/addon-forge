local frame = CreateFrame("Frame", "ForgeExampleFrame", UIParent)
frame:SetWidth(200)
frame:SetHeight(30)
frame:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
frame:Show()
if ForgeTestBridge and ForgeTestBridge.RegisterFrame then
    ForgeTestBridge:RegisterFrame("ForgeExampleFrame", frame)
end

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
        -- Legacy WoW may round GetWidth() to a fractional UI unit depending
        -- on render resolution and UI scale. Test the intended geometry
        -- without requiring floating-point bit-for-bit equality.
        local width = frame:GetWidth()
        ForgeTestBridge:Assert(type(width) == "number"
            and math.abs(width - 200) <= 2,
            "Unexpected frame width: " .. tostring(width) .. " (expected ~200)")
    end)
end
