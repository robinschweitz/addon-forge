# RaidLedger Requirements

This file holds RaidLedger's requirements that were decided after the raid of
2026-10-26. The older loot rules (rolls, tallies, tie-breaks, parking, BoE
rolls, editors) are still only in `RaidLedger/README.md` and its specs; moving
them here is open work (REQUIREMENTS.md FR-14.5).

## Functional Requirements

### FR-RL-001 - Reopening a corpse never adds its loot twice
- **Status:** Implemented (offline)
- **Source:** Raid of 2026-10-26: reopening the boss corpse put its loot into the list several times.
- **Statement:** RaidLedger MUST add each item of a corpse or chest to the loot list once, however often the loot window is opened. An item already listed, rolled or handed out from that corpse MUST NOT be added again. A second copy of the same item on the same corpse MUST still be listed (bundled tokens stay one row).
- **Cause:** Items were recognized by corpse, loot slot and item. After a hand-out the client moves the remaining items up a slot, and a corpse that is not the player's target was named after the latest creature death (a trash kill in between gave it a new name).
- **Acceptance criteria:** Given a corpse with three items, when the master looter hands out the first and opens the corpse again, then the list holds the same three items (one of them awarded) and no new rows. Given an untargeted corpse, when another creature dies and the corpse is opened again, then no item is added. Given a corpse with two copies of one item, when it is opened, then both copies are listed.
- **Evidence:** `examples/RaidLedger/tests/raid_feedback_2026_10_26.spec.lua::FR-RL-001 a corpse reopened after a hand-out lists no item twice`, `::FR-RL-001 an untargeted corpse keeps its name when another creature dies`, `::FR-RL-001 two copies of one item on a corpse are both listed`; `examples/RaidLedger/tests/loot_tracking.spec.lua::handouts from the default master-loot menu are recorded, and a reopened corpse lists items once`. Offline only: no plan step reopens a corpse. ASSUMPTION: the 3.3.5a client lists the remaining items from slot 1 on when a corpse is opened again (the emulator lists what the spec passes).

### FR-RL-002 - Group loot is not recorded
- **Status:** Implemented (offline)
- **Source:** User decision, 2026-10-26; replaces the decision of 2026-10-19 that recorded group-loot wins without a spec.
- **Statement:** RaidLedger MUST NOT record items won with group loot (need, greed or disenchant rolls of the client). Only master-loot hand-outs and the ledger's own actions create awards.
- **Acceptance criteria:** Given group loot, when the chat says `Bob won: [item]` or `You won: [item]` and then `Bob receives loot: [item]`, then no award is added.
- **Evidence:** `examples/RaidLedger/tests/raid_feedback_2026_10_26.spec.lua::FR-RL-002 an item won with group loot is not recorded`. Offline only.

### FR-RL-003 - No trade tracking
- **Status:** Verified Live
- **Source:** User decision, 2026-10-26 ("macht mehr Ärger als alles andere").
- **Statement:** RaidLedger MUST NOT watch trades. An item the master looter keeps for a roll winner MUST be recorded right away as the winner's award (the master looter hands it over), not as "held until traded". An item kept without a roll stays an open item (FR-RL-004) until it is rolled; its roll winner then becomes the recipient at once.
- **Acceptance criteria:** Given a roll won by Alice, when the master looter gives the item to himself, then the award's recipient is Alice, it counts in Alice's tally, and the raid hears that it goes to Alice. Given a completed trade, then no award changes.
- **Evidence:** `examples/RaidLedger/tests/raid_feedback_2026_10_26.spec.lua::FR-RL-003 an item the master looter keeps for the winner is the winner's award at once`, `::FR-RL-003 a completed trade changes no award`; `examples/RaidLedger/tests/open_items.spec.lua::a later roll on an item the master looter holds goes to the winner at once`; `examples/RaidLedger/tests/bag_roll.spec.lua::the winner is the recipient of the same award at once (no trade tracking)`. Live plan `examples/RaidLedger-kept-for-winner-acceptance.json` (formerly `-held-announce-`); `RaidLedger-trade-acceptance.json` was removed. Live session `0424b57ddf78` (bridge run `58c1171ed918`, 2026-10-26): the fixture bot won the roll, Test kept the item, the party heard `geht an Flo... - Main-Spec (Test gibt es weiter).`, and the independent snapshot read state `given`, holder `Test`, spec `ms`, confirmed, no Lua errors. The recipient is checked by the chat line only, since the bot's name is random.

### FR-RL-004 - Open items only in BEUTE
- **Status:** Implemented (offline)
- **Source:** User decision, 2026-10-26.
- **Statement:** Open items (parked with a raider or kept without a roll, waiting for their roll) MUST appear only in the BEUTE tab, under OPEN ITEMS. The VERGABEN tab and its count MUST list them only once they are rolled and handed out. The website export keeps them as `parked` lines.
- **Acceptance criteria:** Given a parked item, then BEUTE lists it under OPEN ITEMS and VERGABEN does not list it. Given that item's roll is won, then VERGABEN lists the award and BEUTE no longer does.
- **Evidence:** `examples/RaidLedger/tests/raid_feedback_2026_10_26.spec.lua::FR-RL-004 an open item is listed in BEUTE only, until its roll is won`; `examples/RaidLedger/tests/open_items.spec.lua::open items are not in VERGABEN; one is rolled from BEUTE like any other`; `examples/RaidLedger/tests/ui_countdown_park.spec.lua::a re-parked award the master looter gives himself is no longer open`. Offline only.

### FR-RL-005 - Disenchanter roll
- **Status:** Verified Live
- **Source:** User decision, 2026-10-26.
- **Statement:** An editor MUST be able to start one disenchanter roll per raid (DE ROLL in BEUTE, or `/ledger deroll`). Everyone in the group may roll `/rnd 100`; other ranges are ignored, the highest roll wins (a tie starts the usual tie-break), and the roll counts in no tally. The winner is the raid's disenchanter until NEW RAID, announced to the raid and shared with the other ledgers. An editor can start it only while no other roll runs, since `/rnd` results go to the latest roll. While a disenchanter is set, DE gives the selected item to the disenchanter, whatever name is in the box; without one, DE keeps today's behaviour (the name in the box, else the player).
- **Acceptance criteria:** Given a started disenchanter roll with rolls of 40 and 87 (1-100) and one of 300 (1-300), when it ends, then the 87 roller is the disenchanter and the raid hears it. Given a disenchanter, when the master looter presses DE on an item nobody wanted, then the item goes to the disenchanter as `disenchanted`, counts for nobody, and no roll starts. Given NEW RAID, then no disenchanter is set.
- **Evidence:** `examples/RaidLedger/tests/raid_feedback_2026_10_26.spec.lua::FR-RL-005 the disenchanter roll takes /rnd 100 only and names the raid's disenchanter`, `::FR-RL-005 DE gives an unwanted item to the disenchanter, whatever the box holds`, `::FR-RL-005 NEW RAID forgets the disenchanter`; `examples/RaidLedger/tests/loot_flow_deDE.spec.lua::FR-RL-005 the disenchanter roll is German and fits beside the roll buttons` (refused while another roll runs, `forge.layoutIssues` empty, sketch `RaidLedger-de-roll.svg` checked). Live plan `examples/RaidLedger-disenchanter-acceptance.json`. Sharing the disenchanter with other ledgers (`D` message) is offline untested. Live session `c59b3ef83f50` (bridge run `5d8647f6c30f`, 2026-10-26): DE ROLL, Test's 1-1000 roll was ignored, the bot's 1-100 roll made it the disenchanter (`[Loot] Flo... ist der Entzauberer dieses Raids`), and after a roll nobody took, DE gave the item to the bot (`wird entzaubert (Flo...`), state `disenchanted`, confirmed, no Lua errors. An earlier session (`b3bb366082e0`) also gave both to the bot but failed on plan checks that expected the exact name `Flo`; a run before that was disturbed by a manual click.

### FR-RL-006 - BEUTE shows the next step
- **Status:** Verified Live
- **Source:** User feedback, 2026-10-26: a friend could not use the window (an item nobody wanted was stuck, the bottom buttons were unclear).
- **Statement:** The selected item in BEUTE MUST be handled in two labelled steps: **1 WÜRFELN** (roll, roll again, free BoE roll) and **2 VERGEBEN** (a name box with ALL, a give button that names the recipient, ENTZAUBERN, GILDENBANK, PARKEN). The state line MUST say in words what happened and what comes next, and the button for that next step MUST be highlighted: ROLL before a roll, the give button after a win, ENTZAUBERN when nobody wanted the item. The give button MUST name the recipient (`VERGEBEN AN BOB`); with an empty box it is disabled and reads `VERGEBEN AN ...`. FREE BOE ROLL is shown only for bind-on-equip items.
- **Acceptance criteria:** Given an item nobody rolled on, then the state line says nobody wanted it, ENTZAUBERN is highlighted and enabled. Given a won roll, then the give button reads `VERGEBEN AN <winner>` and is highlighted. Given a German client with full data, then `forge.layoutIssues` finds nothing.
- **Evidence:** `examples/RaidLedger/tests/loot_steps_deDE.spec.lua::FR-RL-006 before a roll ROLL is the next step; a won roll names its winner on the give button`, plus the state lines and highlights in the FR-RL-007 tests there; `forge.layoutIssues` empty on a German client, sketches `RaidLedger-steps-winner.svg`, `-steps-nobody.svg`, `-steps-open.svg` checked. The new specs failed on the code before the change (checked in a worktree of `4b086ac`). Live session `c18da0d451ba` (bridge run `06c45772a69a`, 2026-10-26, plan `RaidLedger-open-in-loot`): the open item's state line read `Offen: Test hat es.`, and `step-open_selected.png` shows the two steps, ROLL highlighted and the give button reading `VERGEBEN AN ...`. The highlight after a win or with nobody is offline only.

### FR-RL-007 - Every item in BEUTE can be handed out
- **Status:** Verified Live
- **Source:** User feedback, 2026-10-26 (screenshot: an open item with "NIEMAND" offered only ROLL AGAIN).
- **Statement:** Every item in BEUTE - corpse loot, an open item, and an open item whose later roll ended - MUST offer the same hand-outs: give to a name, ENTZAUBERN, GILDENBANK and PARKEN. For an open item they change its award (the holder hands it over); with an empty name box it stays with its holder.
- **Acceptance criteria:** Given an open item whose roll nobody took, when ENTZAUBERN is pressed, then its award becomes `disenchanted` for the disenchanter, and it leaves BEUTE. Given an open item that was not rolled, when GILDENBANK is pressed, then its award becomes `bank` and leaves BEUTE.
- **Evidence:** `examples/RaidLedger/tests/loot_steps_deDE.spec.lua::FR-RL-007 an open item nobody rolled on is disenchanted from BEUTE` (the screenshot case), `::FR-RL-007 an open item that was not rolled goes to the guild bank from BEUTE`; `examples/RaidLedger/tests/disenchant_bank.spec.lua::an existing award goes back to BEUTE and is disenchanted there; the export keeps the state`. Live session `9573c7100628` (bridge run `be24f145d644`, plan `RaidLedger-park-self`): an award sent back to BEUTE was selected there and given to Test with the give button (state `manual`). Disenchanting an open item nobody rolled on is offline only.

### FR-RL-008 - The disenchanter belongs to the raid
- **Status:** Verified Live
- **Source:** User feedback, 2026-10-26 ("der DE-Wurf ist doch ein allgemeiner Wurf").
- **Statement:** The disenchanter roll MUST be started from a raid bar below the loot list that shows the current disenchanter (`ENTZAUBERER: Bob` or `ENTZAUBERER: -`) and an AUSWÜRFELN button (NOCHMAL WÜRFELN once one is set), not from the selected item. It otherwise keeps FR-RL-005.
- **Acceptance criteria:** Given no item selected, when AUSWÜRFELN is pressed, then the disenchanter roll starts. Given a disenchanter, then the bar names them and ENTZAUBERN's tooltip names them.
- **Evidence:** `examples/RaidLedger/tests/loot_steps_deDE.spec.lua::FR-RL-008 the disenchanter is rolled from the raid bar, without a selected item`; `examples/RaidLedger/tests/loot_flow_deDE.spec.lua::FR-RL-005 the disenchanter roll is German and fits beside the roll buttons`. Live session `164041b87f5d` (bridge run `2af22f0b9458`, plan `RaidLedger-disenchanter`): the raid-bar button started the disenchanter roll, the bot won, and DE gave the item to it.

### FR-RL-009 - VERGABEN only corrects
- **Status:** Verified Live
- **Source:** User feedback, 2026-10-26 ("bei Vergabe gibt's dann plötzlich wieder Parken, DE und Bank").
- **Statement:** VERGABEN MUST NOT offer PARK, DE or BANK. A selected award offers: counts as main spec / off spec / nothing, change recipient, ZURÜCK IN BEUTE (the award becomes an open item with its current holder, to be rolled or handed out again in BEUTE), and remove or restore.
- **Acceptance criteria:** Given a recorded award, when ZURÜCK IN BEUTE is pressed, then it leaves VERGABEN and BEUTE lists it under OPEN ITEMS with its holder. VERGABEN has no PARK, DE or BANK button.
- **Evidence:** `examples/RaidLedger/tests/loot_steps_deDE.spec.lua::FR-RL-009 VERGABEN only corrects: no park, DE or bank button`; `examples/RaidLedger/tests/open_items.spec.lua::a recorded award goes back to BEUTE with whoever holds it`; sketch `RaidLedger-awards-corrections.svg` checked. Live sessions `9573c7100628` and `40ee72c1dd54` (bridge run `7e19ef65f757`, plan `RaidWishlist-open`): ZURÜCK IN BEUTE made the award open again and the item was rolled or handed out from BEUTE, with no Lua errors.

### FR-RL-010 - Rolls are announced as raid warnings
- **Status:** Implemented (offline)
- **Source:** User decision, 2026-10-26 ("die Rolls immer über Raidwarnung, damit die Leute es besser mitbekommen").
- **Statement:** In a raid where the player is leader or assistant, the start of every roll (item roll, free BoE roll, later roll, disenchanter roll) and every tie-break MUST be sent as a raid warning (`RAID_WARNING`). Reminders, winners and awards stay in raid chat. Without the right to send raid warnings, or in a party, the announcement goes to raid or party chat as before.
- **Acceptance criteria:** Given a raid assistant, when a roll starts, then its announcement is sent as `RAID_WARNING`. Given a plain raid member who may start rolls (editor list), then it is sent to `RAID`. Given a party, then to `PARTY`.
- **Evidence:** `examples/RaidLedger/tests/loot_steps_deDE.spec.lua::FR-RL-010 an assistant announces roll starts and tie-breaks as raid warnings`, `::FR-RL-010 a raid member without rank announces in raid chat`. Offline only: the live fixture forms a party, not a raid.

### FR-RL-011 - The disenchanter can be chosen by hand
- **Status:** Implemented (offline)
- **Source:** User decision, 2026-10-26.
- **Statement:** Besides the roll (FR-RL-005), an editor MUST be able to set the raid's disenchanter by hand: WÄHLEN in the raid bar opens the raid list, and a click on a name makes that player the disenchanter (also `/ledger de <name>`). It is announced and shared like a rolled disenchanter.
- **Acceptance criteria:** Given the raid bar, when WÄHLEN is pressed and Bob is clicked, then Bob is the disenchanter, the bar says so, the raid hears it, and DE gives items to Bob.
- **Evidence:** `examples/RaidLedger/tests/loot_steps_deDE.spec.lua::FR-RL-011 WÄHLEN makes a raid member the disenchanter without a roll` (also `/ledger de`). Offline only.

### FR-RL-012 - SPÄTER WÜRFELN instead of PARKEN
- **Status:** Verified Live
- **Source:** User decision, 2026-10-26 ("Parken ist verwirrend und steht manchmal mehr im Weg"). Both uses stay: items such as crafting materials are given straight from the boss without a roll, and unique items are handed to a raider to be rolled later.
- **Statement:** PARKEN MUST be renamed SPÄTER WÜRFELN and sit in step 1 (beside WÜRFELN), since it postpones the roll; step 2 holds only hand-outs (give to a name, ENTZAUBERN, GILDENBANK). SPÄTER WÜRFELN MUST ask who keeps the item (the raid list, titled `Wer behält es bis zum Würfeln?`) and hand it to that player, straight from the corpse through master loot while it is still there, so a unique item the master looter already has goes to the raider who holds it until the roll (user, 2026-10-26). Giving an item without a roll stays possible with the give button.
- **Acceptance criteria:** Given an item, then step 1 shows WÜRFELN and SPÄTER WÜRFELN, and step 2 shows no park button. Given an item on the corpse, when SPÄTER WÜRFELN is pressed, then the raid list asks who keeps it and nothing is handed out yet; when Bob is clicked, then the item is given to Bob by master loot and becomes an open item held by Bob.
- **Evidence:** `examples/RaidLedger/tests/loot_steps_deDE.spec.lua::FR-RL-012 SPÄTER WÜRFELN asks who keeps the item and gives it from the corpse` (master-loot candidate checked; sketch `RaidLedger-later-picker.svg`). Live plans `RaidLedger-open-in-loot` and `RaidWishlist-open` click `RaidLedgerMember1_1` (the player) after SPÄTER WÜRFELN. Live sessions `e2cfe402f74b` (bridge run `6f6d0a5dc66c`) and `88d33ec3310a` (bridge run `c212451fdbaa`), 2026-10-26: SPÄTER WÜRFELN opened the list, a click on the player gave the item from the corpse, and it became an open item held by Test. Handing it to another raider from the list is offline only (the fixture's only other member is the bot).

### FR-RL-013 - A tidy window
- **Status:** Verified Live
- **Source:** User feedback, 2026-10-26 (screenshots after the raid: texts running over boxes, misaligned boxes, large gaps, cut texts).
- **Statement:** In every tab, controls in one column MUST share their left and right edges (rows of buttons and boxes end at the same x), section headings of a pane MUST start at the same x, and help texts MUST wrap instead of being cut. This holds at the default size and when the window grows. DESIGN.md readability rules apply.
- **Acceptance criteria:** Given BEUTE at 760x480 and wider, then both rows of step 2 end at the same x, and step 1's buttons start where step 2's do. Given SPIELER, then the correction help text is shown in full. Given EINSTELLUNGEN and RAID, then their section headings start at the same x. `forge.layoutIssues` finds nothing on a German client with full data.
- **Evidence:** `examples/RaidLedger/tests/loot_steps_deDE.spec.lua::FR-RL-013 the steps share one grid, at the default size and wider` (edges compared with `forge.rect`, sketches `RaidLedger-steps-grid.svg` and `-steps-grid-wide.svg` checked). The headings of EINSTELLUNGEN and RAID start at x = 12 in the code; the sketches draw labels without a fixed width centred in an over-estimated box, which looked like misalignment. The SPIELER hint wraps in the client (two lines); sketches do not wrap. ASSUMPTION until a live screenshot of those tabs. Live: `step-open_selected.png` of session `c8feceeb768e` shows both steps starting and ending at the same x in the client.
