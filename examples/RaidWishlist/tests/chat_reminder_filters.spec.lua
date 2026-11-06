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
    forge.click("RaidWishlistSettingsOpen")
    forge.frame("RaidWishlistReminderKeywords"):SetText("roll, würfel")
    forge.click("RaidWishlistReminderSave")
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

-- User report 2026-11-02: a manual "/rw roll [item]" never opened a prompt.
test("a raid warning is a reminder too", function()
    forge.click("RaidWishlistSkip")
    forge.chatEvent("CHAT_MSG_RAID_WARNING", "roll it now " .. CREST, "Lead")
    expect("RaidWishlistPrompt").toBeShown()
    forge.click("RaidWishlistSkip")
end)

-- FR-RW-007: an item already won this raid still gets its reminder.
test("a received item still gets a chat reminder", function()
    forge.fire("CHAT_MSG_ADDON", "FLLedger", "A;Lead-1792131000;Lead;1;1;1792131001;20513;;Tester;given;1;ms;50;1;100;Tester;1;;21:01", "RAID", "Lead")
    expect(forge.saved("RaidWishlistDB").chars.Tester.items[1].received).toBe(true)
    forge.chatEvent("CHAT_MSG_RAID", "roll now " .. CREST, "Lead")
    expect("RaidWishlistPrompt").toBeShown()
    expect(forge.findText("already received", true)).toBeTruthy()
end)

-- User decision 2026-11-06: by default no keyword is needed, and saving an
-- empty keyword box goes back to that. A saved old default is dropped.
test("without keywords any master-looter line with a wished item reminds", function()
    forge.click("RaidWishlistSkip")
    forge.click("RaidWishlistSettingsOpen")
    forge.frame("RaidWishlistReminderKeywords"):SetText("")
    forge.click("RaidWishlistReminderSave")
    expect("RaidWishlistSettingsPanel").toBeHidden()
    expect(forge.saved("RaidWishlistDB").chars.Tester.reminderKeywords).toBeNil()
    forge.chatEvent("CHAT_MSG_RAID", CREST .. " bitte", "Lead")
    expect("RaidWishlistPrompt").toBeShown()
    forge.click("RaidWishlistSkip")
    forge.chatEvent("CHAT_MSG_RAID", "[Loot] " .. CREST .. " - Alice's roll counts as MS (54).", "Lead")
    expect("RaidWishlistPrompt").toBeHidden()
    forge.slash("/wish remind all")
    forge.chatEvent("CHAT_MSG_RAID", CREST .. " bitte", "Alice")
    expect("RaidWishlistPrompt").toBeShown()
    forge.click("RaidWishlistSkip")
    forge.slash("/wish remind master")
    forge.chatEvent("CHAT_MSG_RAID", CREST .. " jetzt", "Alice")
    expect("RaidWishlistPrompt").toBeHidden()
end)

test("a saved old default 'roll,würfel' becomes no keyword after /reload", function()
    local char = forge.saved("RaidWishlistDB").chars.Tester
    char.reminderKeywords, char.keywordsChecked = "roll,würfel", nil
    forge.reload()
    forge.slash("/wish")
    forge.click("RaidWishlistSettingsOpen")
    expect(forge.frame("RaidWishlistReminderKeywords"):GetText()).toBe("")
    expect(forge.layoutIssues("RaidWishlistSettingsPanel")).toEqual({})
    forge.sketch("settings-no-keywords", RaidWishlistSettingsPanel)
    forge.click("RaidWishlistReminderCancel")
end)

-- Raid log 2026-11-06: the master looter posted "t [item] 2" several times
-- and only the first line opened a prompt. Every line is a new roll.
test("a repeated line reminds again, also after rolling; auto-roll rolls each time", function()
    local repeats = {}
    forge.stub("RandomRoll", function(low, high) table.insert(repeats, { low, high }) end)
    local char = forge.saved("RaidWishlistDB").chars.Tester
    expect(char.reminderOn).toBe(true)
    expect(char.reminderKeywords).toBeNil()
    forge.raid({ "Lead", "Alice" })
    forge.stub("GetLootMethod", function() return "master", nil, 1 end)   -- Lead is master looter
    forge.chatEvent("CHAT_MSG_RAID", "t " .. CREST .. " 2", "Lead")
    expect("RaidWishlistPrompt").toBeShown()
    forge.click("RaidWishlistRoll")
    expect(#repeats).toBe(1)
    forge.chatEvent("CHAT_MSG_RAID", "t " .. CREST .. " 2", "Lead")
    expect("RaidWishlistPrompt").toBeShown()
    -- A repeat while the prompt is open restarts its 30 seconds.
    forge.advance(20, 0.25)
    forge.chatEvent("CHAT_MSG_RAID", "t " .. CREST .. " 2", "Lead")
    forge.advance(20, 0.25)
    expect("RaidWishlistPrompt").toBeShown()
    forge.click("RaidWishlistSkip")
    expect(#repeats).toBe(1)

    forge.slash("/wish auto on")
    forge.chatEvent("CHAT_MSG_RAID", "t " .. CREST .. " 2", "Lead")
    forge.advance(2, 0.25)
    forge.chatEvent("CHAT_MSG_RAID", "t " .. CREST .. " 2", "Lead")
    forge.advance(2, 0.25)
    expect(#repeats).toBe(3)
    forge.slash("/wish auto off")
end)
