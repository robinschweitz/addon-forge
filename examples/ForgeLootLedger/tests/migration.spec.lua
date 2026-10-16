-- Ledgers saved by version 1.0 (no award IDs) keep working, and the German
-- client's loot message confirms a handout.
local CREST = "|cffa335ee|Hitem:20513:0:0:0:0:0:0:0:80|h[Abyssisches Wappen]|h|r"

before_load(function()
    forge.locale("deDE", {
        RANDOM_ROLL_RESULT = "%1$s würfelt. Ergebnis: %2$d (%3$d-%4$d)",
        LOOT_ITEM = "%s bekommt Beute: %s.",
        LOOT_ITEM_SELF = "Ihr erhaltet Beute: %s.",
    })
    forge.item(20513, { name = "Abyssisches Wappen", link = CREST, quality = 4 })
    forge.setSaved("ForgeLootLedgerDB", { history = {
        { item = CREST, recipient = "Newer", rolls = 3, time = "21:10" },
        { item = CREST, recipient = "Older", rolls = 1, time = "21:00" },
    } })
end)

test("old awards get IDs oldest first and appear in the export", function()
    local db = forge.saved("ForgeLootLedgerDB")
    expect(db.history[2].id).toBe(1)
    expect(db.history[1].id).toBe(2)
    expect(db.history[1].itemID).toBe(20513)
    expect(db.history[1].state).toBe("manual")
    forge.slash("/forgeloot raid 7")
    forge.slash("/forgeloot export")
    expect(forge.text("ForgeLootLedgerExportText")).toContain("\n1;0;-;20513;Older;manual;-;-;-;-\n2;0;-;20513;Newer;manual;-;-;-;-")
end)

test("a German loot message confirms a handout to yourself", function()
    forge.masterLoot({ "Tester" })
    forge.openLoot({ { id = 20513 } })
    GiveMasterLoot(1, 1)
    expect(forge.saved("ForgeLootLedgerDB").history[1].confirmed).toBe(false)
    forge.advance(0.1)
    expect(forge.saved("ForgeLootLedgerDB").history[1].confirmed).toBe(true)
    expect(forge.saved("ForgeLootLedgerDB").history[1].state).toBe("held")
    expect(#forge.errors()).toBe(0)
end)
