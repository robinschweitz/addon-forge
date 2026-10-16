# ForgeLootWishlist

The raid member's side of [ForgeLootLedger](../ForgeLootLedger) for WoW 3.3.5a
(Interface 30300). Members import their wishlist from the guild website, get a
one-click roll (or an automatic roll) when the raid lead rolls out a wishlisted
item, and see who got what this raid. The raid lead uses ForgeLootLedger; the
two addons talk over addon messages (prefix `FLLedger`). Live acceptance plans:
`../ForgeLootWishlist-acceptance.json` (prompt) and
`../ForgeLootWishlist-auto-acceptance.json` (auto-roll).

Open it with `/flw` (or `/lootwish`).

## Importing the wishlist

On the guild website, copy your wishlist export, click **IMPORT** (or
`/flw import`), paste it (Ctrl+V) and press **IMPORT WISHLIST**. An import
replaces the previous list. An export made for another character is refused,
so an alt never rolls on a main's list.

The website exports one character's list:

```text
WL1;<character>;<export time, Unix seconds>
<item ID>;<ms|os>;<points>;<priority>;<note>
```

```text
WL1;Thorgar;1792130000
50415;ms;20;1;BiS weapon
52027;ms;0;2;
50074;os;0;3;for my off spec
```

- `ms` rolls main spec (`/rnd 100`), `os` off spec (`/rnd 99`).
- `points` (0, 10, 20, 30, 40 or 50) enhance a main-spec roll: 20 rolls
  21-120. Off spec cannot use points. The website deducts used points from the
  raid's loot export, as before.
- `priority` orders the list (1 first); the note is shown in the roll prompt.
- Lines that break these rules are skipped and counted in the import message.

## Rolling

When the raid lead's ForgeLootLedger starts a roll on an item from your list,
a prompt appears at the top of the screen: **ROLL MS 21-120** (your wishlist's
spec and points) or **SKIP**. It closes when the roll ends.

**AUTO-ROLL** (button, or `/flw auto on|off`) rolls for you instead, about a
second after the roll starts, for example while you are away from the keyboard.

Either way the addon rolls at most once per roll (the ledger only counts your
first roll), joins a tie-break only if you are one of the tied players, and
does not roll on items you already received this raid.

## Open items

**OPEN ITEMS** lists loot that is still waiting to be rolled: items on the
corpse, items the master looter keeps for a later roll, and items parked with
another raider (e.g. unique items), with where they are and their status:
`OPEN`, `ROLLING NOW` or `WON: <name>`. Items on your wishlist are marked
`WISHLIST`. An item parked with you is not yours yet: you still get the prompt
or auto-roll when it is rolled.

## This raid

The lower list shows every award the raid lead's ledger shares: item,
recipient and spec, with removed awards greyed out. Your items and items on
your wishlist are highlighted; hover a row for the item tooltip. The header
shows your own tally this raid (main spec and off spec items, tokens not
counted), which decides close rolls. An item the master looter holds for you
counts as yours, and its wishlist entry shows **RECEIVED**.

After a login or `/reload` the addon asks the group for this raid's awards
(`/flw sync` asks again). A newer raid replaces the list automatically.

## Commands

| Command | Effect |
| --- | --- |
| `/flw` | Show or hide the window |
| `/flw import` | Paste a wishlist export |
| `/flw auto on` / `off` | Roll automatically / show the roll prompt |
| `/flw sync` | Ask the raid lead's ledger for this raid's awards |
