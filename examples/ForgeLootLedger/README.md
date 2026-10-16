# ForgeLootLedger

Raid roll and master-loot award ledger for WoW 3.3.5a (Interface 30300). The
suite's reference addon: see `tests/` and `../ForgeLootLedger-acceptance.json`.
The loot tracking was taken over from RaidSync
([robinschweitz/wow-addons](https://github.com/robinschweitz/wow-addons)).

## Rolls

Opening a loot window lists every item at or above the group's loot threshold.
Select an item and type `/forgeloot start` to start a 30-second `/rnd`. Only
1-100 rolls count, and only a player's first roll. A shared top roll starts a
15-second tie-break among the tied players. Announcements go to raid, then
party, then local chat.

## Awards

- **GIVE LOOT + RECORD**: while the item is still in the master-loot window,
  the award button hands it to the recipient with `GiveMasterLoot`. The ledger
  records the award and marks it confirmed once the server's loot message
  arrives (an unconfirmed award shows `?`).
- Handouts from the default master-loot menu are recorded the same way.
- **RECORD AWARD**: without the item in a master-loot window, the award is
  recorded by hand (`MANUAL`).
- Items you give to yourself are `HELD BY YOU`. When you trade one to another
  player and the trade completes, the oldest held copy moves to that player.
  Trades between other players are not visible to the addon.
- Each award stores the item ID, the creature ID of the corpse (the dead target,
  or the last creature death for chests), the winner's roll and the time.
  Reopening the same corpse does not list its items twice.

## Roll log

Every award keeps what was rolled for it, and the log is saved with the ledger.
Click an award in the list (scroll it with the mouse wheel) and the left pane
shows its rolls instead of the loot items. It lists counted rolls highest first,
then each tie-break round, and marks the winner. Rolls that did not count stay
listed in grey with the reason: `re-roll`, a wrong range such as `1-1000`, or
`not in tie-break`. Long logs scroll with the mouse wheel. Click the award
again, or open new loot, to get the loot items back. Awards recorded before
version 1.1 have no roll log.

## Clearing old loot

**CLEAR** (on the award list), **NEW RAID** (in the export) and
`/forgeloot newraid` ask first, then empty the award ledger and forget the raid
ID. Export before clearing. `/forgeloot newraid confirm` clears without asking.

## Corrections

Click an award in the list, pick or type the recipient and press
**CHANGE RECIPIENT**. Or use the slash commands:

| Command | Effect |
| --- | --- |
| `/forgeloot set <#> <name>` | Change the recipient of award `#` |
| `/forgeloot set <#>` | Change it to your current player target |
| `/forgeloot del <#>` | Remove award `#` (kept in the export as `deleted`) |

A removed award can be restored by setting a recipient again.

## Website export (RS2)

`/forgeloot raid <id>` sets the website's raid ID, and **EXPORT** (or
`/forgeloot export`) shows the selected text to copy with Ctrl+C.
`/forgeloot newraid` (or CLEAR) empties the ledger and forgets the raid ID; export first.

```text
RS2;LOOT;42;Raidleader;1760000000;1760003600
1;1760000300;36612;50415;Thorgar;given;87
2;1760000301;36612;52027;Raidleader;held;-
3;1760000400;-;50074;Aelira;manual;-
4;1760000420;36612;50415;Frostlin;deleted;64
```

Header: `RS2;LOOT;<raid ID>;<recorder>;<first award time>;<export time>`.
Lines, oldest first: `<award ID>;<time>;<creature ID or ->;<item ID or ->;<recipient>;<state>;<recipient's roll or ->`.
Times are Unix seconds.

States: `given` (handed out or traded by you), `held` (with the recorder),
`manual` (recorded or corrected by hand), `deleted` (removed; delete it on the
website if it was imported before).

Changes from RaidSync's `RS1|LOOT`:

- `;` replaces `|`, which starts escape sequences such as `|T` and `|c` in a
  WoW edit box.
- Removed awards stay in the export as `deleted`, so the website can remove
  lines it imported earlier.
- The header carries the export time and each line carries the recipient's roll.
- Award IDs never change, even across `newraid`.
