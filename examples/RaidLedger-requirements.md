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
