-- Every control has a tooltip (raid feedback 2026-10-19: "tooltips everywhere").
-- Walks the visible buttons and edit boxes of each panel and hovers them.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
end)

local function controls(frame, out)
    out = out or {}
    for _, child in ipairs({ frame:GetChildren() }) do
        if child.IsVisible and child:IsVisible() then
            local kind = child:GetObjectType()
            if kind == "Button" or kind == "EditBox" then table.insert(out, child) end
            if child.GetChildren then controls(child, out) end
        end
    end
    return out
end

local function describe(control)
    local text = control.GetText and control:GetText()
    local parent = control:GetParent()
    return (control:GetName() or "?") .. " " .. tostring(text) .. " in " .. tostring(parent and parent:GetName())
end

local function untipped()
    local missing = {}
    for _, control in ipairs(controls(RaidLedgerFrame)) do
        GameTooltip:Hide()
        forge.hover(control)
        local lines, shown = forge.tooltip()
        if not shown or #lines == 0 then table.insert(missing, describe(control)) end
        forge.hover(control, true)
    end
    return missing
end

test("the loot view: every control explains itself", function()
    forge.raid({ "Tester", "Alice", "Bob" })
    forge.openLoot({ { id = 20513 } })
    forge.slash("/ledger start")
    forge.roll("Alice", 50)
    forge.advance(31, 0.25)
    expect(untipped()).toEqual({})
    forge.click(forge.frame("RaidLedgerAllMembers"))   -- the whole raid by group
    expect(untipped()).toEqual({})
    forge.click(forge.frame("RaidLedgerAllMembers"))
end)

test("the export, the raid setup and the settings too", function()
    forge.slash("/ledger export")
    expect(untipped()).toEqual({})
    forge.slash("/ledger setup")
    expect(untipped()).toEqual({})
    forge.slash("/ledger settings")
    expect(untipped()).toEqual({})
end)

test("the awards and the tally too, with something selected", function()
    forge.click("RaidLedgerTabButtonLoot")
    forge.click("RaidLedgerItemRow1")
    forge.type("RaidLedgerRecipient", "Alice")
    forge.click("RaidLedgerAward")
    forge.click("RaidLedgerTabButtonAwards")
    forge.click("RaidLedgerAwardLine1")
    expect(untipped()).toEqual({})
    forge.click("RaidLedgerTabButtonTally")
    forge.click("RaidLedgerTallyRow1")
    expect(untipped()).toEqual({})
end)
