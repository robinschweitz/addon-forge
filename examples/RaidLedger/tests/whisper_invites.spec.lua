-- FR-RL-020: with the switch on, a listed player can whisper "inv". The sender
-- comes from the event; everyone and everything else is ignored silently.
local INVITES = "RS2;INV;42;ICC 25 Mittwoch;25\nTank;TANK;Krieger;0\nHealer;HEAL;Priester;0\nStandby;DD;Jäger;1"

local invited, whispers = {}, {}

before_load(function()
    forge.stub("InviteUnit", function(name) table.insert(invited, name) end)
    forge.stub("ConvertToRaid", function() end)
    local send = SendChatMessage
    forge.stub("SendChatMessage", function(text, kind, ...)
        if kind == "WHISPER" then table.insert(whispers, text) end
        return send(text, kind, ...)
    end)
end)

local function whisper(text, sender)
    forge.fire("CHAT_MSG_WHISPER", text, sender)
    forge.advance(1)
end

test("FR-RL-020 the switch is off by default and nobody is invited", function()
    forge.click("RaidLedgerRaidButton")
    forge.type("RaidLedgerInviteText", INVITES)
    forge.clickText("READ")
    expect(forge.text("RaidLedgerWhisperInvites")).toBe("WHISPER INVITES: OFF")
    whisper("inv", "Tank")
    expect(invited).toEqual({})
end)

test("FR-RL-020 a listed player gets one invite for an exact inv", function()
    forge.click("RaidLedgerWhisperInvites")
    expect(forge.text("RaidLedgerWhisperInvites")).toBe("WHISPER INVITES: ON")
    expect(forge.saved("RaidLedgerDB").setup.whisperInvites).toBe(true)
    whisper("  INV ", "Tank")
    expect(invited).toEqual({ "Tank" })
    whisper("inv", "Tank")
    expect(invited).toEqual({ "Tank" })
end)

test("FR-RL-020 strangers, other words and group members are ignored without an answer", function()
    invited = {}
    whisper("inv", "Fremder")
    whisper("inv please", "Healer")
    whisper("|Hplayer:Healer|h", "Fremder")
    forge.party({ "Healer" })
    whisper("inv", "Healer")
    forge.party({})
    expect(invited).toEqual({})
    expect(whispers).toEqual({})
end)

test("FR-RL-020 the bench counts only with BENCH: YES", function()
    whisper("inv", "Standby")
    expect(invited).toEqual({})
    forge.clickText("BENCH: NO")
    whisper("inv", "Standby")
    expect(invited).toEqual({ "Standby" })
end)

test("FR-RL-020 a raid member without rights invites nobody", function()
    invited = {}
    forge.raid({ "Tester", "Alice" })
    forge.leader(false)
    whisper("inv", "Healer")
    expect(invited).toEqual({})
    forge.leader(true)
    whisper("inv", "Healer")
    expect(invited).toEqual({ "Healer" })
end)

test("FR-RL-020 the word can be chosen, and an empty box means inv again", function()
    invited = {}
    forge.leader(true)
    forge.raid({})
    forge.advance(70)    -- the earlier invites ran out
    forge.type("RaidLedgerWhisperWord", "Komm")
    expect(forge.saved("RaidLedgerDB").setup.whisperWord).toBe("Komm")
    whisper("inv", "Healer")
    expect(invited).toEqual({})
    whisper(" komm", "Healer")
    expect(invited).toEqual({ "Healer" })
    forge.type("RaidLedgerWhisperWord", "")
    expect(forge.saved("RaidLedgerDB").setup.whisperWord).toBeNil()
    whisper("inv", "Tank")
    expect(invited).toEqual({ "Healer", "Tank" })
end)
