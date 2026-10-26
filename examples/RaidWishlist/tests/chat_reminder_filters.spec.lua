-- The chat reminder must not react to item names that happen to contain a
-- keyword, nor to RaidLedger's own "[Loot]" announcements: RaidLedger starts
-- its rolls by addon message, and its other announcements (parked items, BoE
-- winners, counted rolls) are no roll to join.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssal Crest]|h|r"
local TROLLBANE = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Trollbane]|h|r"

before_load(function()
    forge.item(20513, { name = "Abyssal Crest", link = CREST, quality = 4 })
end)

local rolls = {}

local function left(region) return math.floor(region:GetLeft() + 0.5) end
local function right(region) return math.floor(region:GetRight() + 0.5) end
local function bottom(region) return math.floor(region:GetBottom() + 0.5) end

test("the reminder is off until the player switches it on", function()
    forge.slash("/wish edit")
    forge.type("RaidWishlistEditorItem", "20513")
    forge.click("RaidWishlistEditorSave")
    forge.raid({ "Lead", "Alice" })
    forge.stub("GetLootMethod", function() return "master", nil, 1 end)
    forge.stub("RandomRoll", function(low, high) table.insert(rolls, { low, high }) end)
    forge.chatEvent("CHAT_MSG_RAID", "roll " .. CREST, "Lead")
    expect("RaidWishlistPrompt").toBeHidden()

    forge.click("RaidWishlistSettingsOpen")
    forge.click("RaidWishlistReminderOn")
    forge.click("RaidWishlistReminderCancel")
    expect(forge.saved("RaidWishlistDB").chars.Tester.reminderOn).toBe(nil)
    forge.click("RaidWishlistSettingsOpen")
    forge.click("RaidWishlistReminderOn")
    expect(forge.layoutIssues("RaidWishlistSettingsPanel")).toEqual({})
    forge.click("RaidWishlistReminderSave")
    expect(forge.saved("RaidWishlistDB").chars.Tester.reminderOn).toBe(true)
    forge.chatEvent("CHAT_MSG_RAID", "roll " .. CREST, "Lead")
    expect("RaidWishlistPrompt").toBeShown()
    forge.click("RaidWishlistSkip")
    forge.slash("/wish remind off")
    expect(forge.saved("RaidWishlistDB").chars.Tester.reminderOn).toBe(nil)
    forge.slash("/wish remind on")
end)

test("a keyword inside an item name is no reminder", function()
    forge.chatEvent("CHAT_MSG_RAID", TROLLBANE, "Lead")
    expect("RaidWishlistPrompt").toBeHidden()
    forge.chatEvent("CHAT_MSG_RAID", "Roll " .. TROLLBANE, "Lead")
    expect("RaidWishlistPrompt").toBeShown()
    -- Raider screenshot 2026-10-26: the buttons fill the row with even margins.
    local prompt = RaidWishlistPrompt
    expect(left(RaidWishlistRoll) - left(prompt)).toBe(12)
    expect(right(prompt) - right(RaidWishlistSkip)).toBe(12)
    expect(bottom(RaidWishlistRoll) - bottom(prompt)).toBe(12)
    expect(forge.layoutIssues("RaidWishlistPrompt")).toEqual({})
    forge.sketch("prompt-margins", prompt)
    forge.click("RaidWishlistSkip")
end)

test("RaidLedger announcements never start a reminder", function()
    forge.chatEvent("CHAT_MSG_RAID", "[Loot] " .. CREST .. " is parked with Alice until it is rolled.", "Lead")
    forge.chatEvent("CHAT_MSG_RAID", "[Loot] " .. CREST .. " - free BoE roll for any character! /rnd 100, 30 seconds.", "Lead")
    forge.chatEvent("CHAT_MSG_RAID", "[Loot] " .. CREST .. " - free BoE roll won by Alice (88).", "Lead")
    forge.chatEvent("CHAT_MSG_RAID", "[Loot] " .. CREST .. " - Alice's roll counts as MS (54).", "Lead")
    forge.chatEvent("CHAT_MSG_RAID_LEADER", "[Loot] " .. CREST .. " wird bis zum Auswürfeln von Alice verwahrt.", "Lead")
    expect("RaidWishlistPrompt").toBeHidden()

    forge.slash("/wish auto on")
    forge.chatEvent("CHAT_MSG_RAID", "[Loot] " .. CREST .. " - free BoE roll won by Alice (89).", "Lead")
    forge.advance(3, 0.25)
    expect(rolls).toEqual({})
end)

test("German keywords keep their umlauts when saved and still match", function()
    forge.slash("/wish auto off")
    forge.click("RaidWishlistSettingsOpen")
    forge.frame("RaidWishlistReminderKeywords"):SetText("Würfel, roll")
    forge.click("RaidWishlistReminderSave")
    expect(forge.saved("RaidWishlistDB").chars.Tester.reminderKeywords).toBe("Würfel,roll")
    forge.chatEvent("CHAT_MSG_RAID", "Jetzt würfeln: " .. CREST, "Lead")
    expect("RaidWishlistPrompt").toBeShown()
end)
