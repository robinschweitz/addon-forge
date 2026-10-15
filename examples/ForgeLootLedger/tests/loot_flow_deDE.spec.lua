-- German client: RANDOM_ROLL_RESULT uses positional specifiers, and every
-- system chat line (e.g. idle-logout notices) reaches the roll parser.
before_load(function()
    forge.locale("deDE", { RANDOM_ROLL_RESULT = "%1$s würfelt. Ergebnis: %2$d (%3$d-%4$d)" })
    forge.item(20513, { name = "Abyssisches Wappen", link = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssisches Wappen]|h|r", quality = 4 })
end)

test("unrelated system messages do not raise Lua errors", function()
    forge.fire("CHAT_MSG_SYSTEM", "Ihr wart für einige Zeit inaktiv und werdet jetzt vom Spiel abgemeldet.")
    expect(#forge.errors()).toBe(0)
end)

test("German /rnd results are recorded and the highest wins", function()
    forge.openLoot({ { id = 20513 } })
    forge.slash("/forgeloot start")
    forge.roll("Anna", 12)
    forge.roll("Bernd", 88)
    forge.advance(31, 0.25)
    expect(forge.chat()).toContain("won by Bernd (88)")
end)
