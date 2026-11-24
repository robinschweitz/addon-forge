-- What the Ace3 libraries read while their files load, before any spec can stub it.
test("IsLoggedIn is true after PLAYER_LOGIN and the realmList CVar is set", function()
    expect(IsLoggedIn()).toBeTruthy()
    expect(GetCVar("realmList")).toBeTruthy()
end)

test("GetSpellInfo and GetSpellLink answer with the spell's name", function()
    forge.spell(47436, "Schlachtruf")
    expect(GetSpellInfo(47436)).toBe("Schlachtruf")
    expect(GetSpellInfo(45438)).toBe("Spell 45438")
    expect(GetSpellLink(47436)).toBe("|cff71d5ff|Hspell:47436|h[Schlachtruf]|h|r")
end)

test("the FrameXML functions the libraries and hooks need exist", function()
    expect(type(ChatEdit_InsertLink)).toBe("function")
    expect(type(JumpOrAscendStart)).toBe("function")
end)

test("geterrorhandler always gives a handler, and what it gets is reported", function()
    geterrorhandler()("from a library's xpcall")
    local errors = forge.errors()
    expect(errors[#errors]).toContain("from a library's xpcall")
    table.remove(errors)
end)
