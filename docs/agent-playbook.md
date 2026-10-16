# Agent playbook: building 3.3.5a addons that actually work

Hard-won knowledge from building and live-verifying
[`examples/ForgeLootLedger`](../examples/ForgeLootLedger) (October 2026), the reference addon:
its specs and acceptance plan show every technique below in use. Read this before creating, repairing or testing an addon, and
before changing the Forge test pipeline. Facts here were observed on the real
isolated test client (German `deDE`, build 12340) unless marked otherwise.

## The loop that works

1. `forge new Name` (or edit `projects/Name/`). Lua 5.1, `## Interface: 30300`.
2. `forge check projects/Name` until clean. "unknown global" = almost always a
   hallucinated or post-Wrath API; ask `forge api lookup NAME` / `Widget:Method`.
3. Write offline specs in `projects/Name/tests/*.spec.lua` **before** fixing a
   bug: reproduce it as a failing spec, then fix, then watch it pass.
4. `forge spec projects/Name` until green, including `forge.layoutIssues(frame)`
   for any UI.
5. Write the acceptance plan with checks that observe the addon (`chat_contains`,
   `global_equals`, `frame_text_contains`, `event_fired`, `no_lua_errors`) and
   `steps` that drive it (`slash`, `roll`, `wait`, `click`).
6. Live run: close WoW, then
   `forge --config forge.local.toml agent session projects/Name-acceptance.json --approve-fixtures`.
   Use `agent session` after **any** addon change: a running client keeps the
   code it loaded at startup (`run-plan` refuses stale deploys for this reason).
   See [Who runs live sessions](#who-runs-live-sessions).
7. Read the JSON result, then the screenshot in `projects/.forge-runs/`. Fix,
   repeat. Never weaken a check; tighten one that could pass vacuously.
   SavedVariables persist between live runs: start the plan's steps from a
   known state (ForgeLootLedger's first step is `/forgeloot newraid confirm`),
   or checks can pass on data from an earlier run.

## Who runs live sessions

`--approve-fixtures` changes the disposable local test realm (spawns and kills
creatures, creates bot players and parties), so it needs the human's approval.
The human may give that approval once, as a standing permission for
`agent session ... --approve-fixtures` on the local test realm. With it the
agent runs live sessions itself:

1. **Say so before every run.** The session launches the test client on the
   human's desktop and sends keypresses; nobody may type or use WoW for the
   ~2 minutes it takes.
2. Close any running test client first (only `F:\Wow\wow_second`, never
   another WoW installation). A session leaves the client running when it
   ends, and the next `agent session` refuses to start ("Close test WoW before
   starting the session"): check the process path, then stop that process.
3. Run the session in the background from the repository root and read the
   JSON result and the `.forge-runs/` evidence yourself.
4. Report pass/fail with the run ID and what the checks proved.

Without standing permission, give the human the exact command and read their
terminal when they say "check". The agent can only read the desktop app's own
Terminal tab; a run started in another window must be pasted.

## WoW 3.3.5a client facts (verified live)

- **Widget methods differ from later expansions.** 3.3.5a `Button` has no
  `SetTextColor`, `SetJustifyH` or `SetTextInsets`; style the button's own
  `FontString` (`button:SetFontString(fs)`). `FontString:SetWordWrap` exists
  and truncates long single-line text. `SetMaxLines` does not exist.
  With `forge api dump` taken, the offline emulator fails exactly like the
  client on a missing method.
- **Localized GlobalStrings use positional specifiers.** deDE
  `RANDOM_ROLL_RESULT` is `%1$s würfelt. Ergebnis: %2$d (%3$d-%4$d)`. Strip
  `%n$` before turning a format string into a Lua pattern, or `%1` becomes an
  invalid back-reference (`invalid capture index`). Real chat line:
  `Test würfelt. Ergebnis: 61 (1-100)`.
- **Creature and item names arrive in the client's language** (Crimson Templar
  = `Purpurroter Templer`). Never match English names; use item IDs
  (`item:20513` inside links) or look names up per locale.
- **`OnUpdate` only runs for visible frames.** Timers on a window stop when the
  user hides it; drive timers from a separate always-shown frame.
- **Every `CHAT_MSG_SYSTEM` reaches a roll parser**, including idle-logout
  notices; a parser bug fires on all of them.
- **SavedVariables are assigned after all addon files run**, before
  `ADDON_LOADED`. Never read them at file load.
- **`PARTY_INVITE` declines itself when hidden unaccepted.** Find it with
  `StaticPopup_Visible("PARTY_INVITE")`, never assume `StaticPopup1`.
- **The tooltip background texture is translucent.** Use
  `Interface\ChatFrame\ChatFrameBackground` for opaque panels.
- In a party (not raid), addon announcements must use `SendChatMessage(msg, "PARTY")`
  or members never see them.

## WoWControlSDK facts (verified live)

- SDK `lua.evaluate` may call protected `TargetUnit`, but opening loot
  (`InteractUnit`) needs a hardware event: bind `INTERACTTARGET` to a fixed
  unbound chord, press it once with `SendInput`, restore the binding.
- Lua numbers come back as JSON **floats** (`1.0`); compare numerically.
- The pipe is **message-mode and single-threaded**: replies over 64 KB arrive
  in `ERROR_MORE_DATA` pieces, and between requests no pipe instance exists
  (`CreateFile` error 2/231). `wowcontrol.request` handles both.
- A client launched through the injector has had no real input, so WoW treats
  it as idle from login. The SDK's `IdleLogoutHook` blocks the logout, so the
  idle `CAMP` dialog loops every few seconds and hides other dialogs. One press
  of the unbound `CTRL-SHIFT-F11` after login fixes it (`reset_idle_timer`).
- Calling `lua.evaluate("return UnitName('player')")` during world entry
  crashed the pinned SDK build; identity is checked with `unit.get` first.

## Test-environment facts

- All project addons are enabled in the test client. Bridge errors from other
  addons are reported as `foreign_errors` and do not fail the addon under test;
  errors without an addon path still count.
- The bridge report is capped near 28 KB; it sheds chat, then error counts,
  then events. Repeated errors are stored once with a count.
- Plan `chat_contains` is a substring match: `"5 seconds left"` also matches
  `"15 seconds left"`. Use distinctive text (`" - 5 seconds left!"`).
- Ties cannot be forced live (the server chooses `/rnd` results); cover them
  offline.
- The `master_loot` fixture's bot rolls with `peer_roll`: `MSG_RANDOM_ROLL`
  is opcode `0x1FB` with `uint32 min, uint32 max` (AzerothCore `Opcodes.h`,
  `HandleRandomRollOpcode`); the server broadcasts the result to the group, so
  the client sees a normal "X würfelt. Ergebnis: N (1-100)" line. Verified
  live in run `b2b299f6e36e`, where the bot won and `GiveMasterLoot` to it was
  confirmed by the deDE `LOOT_ITEM` line ("X bekommt Beute: ...").
- `peer_trade` trades from the graphical character to the bot. The bot must be
  listening before the client calls `InitiateTrade`, or `BEGIN_TRADE` arrives
  unobserved (the fixture writes `cmd-NNN.armed` first). A just-looted BoP item
  (Abyssal Crest) is tradable to a party member who was present.
- On trade completion the client fires `TRADE_PLAYER_ITEM_CHANGED` again
  (twice in total for one item), `TRADE_CLOSED` twice and one
  `UI_INFO_MESSAGE`. An addon that reads its trade slots at the last item
  change saw no items and recorded nothing (run `1445c70cd623`); snapshot the
  offer in a `hooksecurefunc("AcceptTrade", ...)` hook instead (passed in run
  `b1b2079d8755`).
- A session's final screenshot (`RUN_ID.png`) shows the end state; use
  `screenshot` steps for anything in between.

## How to debug a failing live run

1. Read the result JSON: `stage` says where it failed (`static`, `offline`,
   `deploy`, `fixture`, `steps`, then checks). In the Claude desktop app the
   user's terminal can be read directly.
2. Open the screenshots in `projects/.forge-runs/`. They showed, among other
   things, that "failed" loot actually opened (a float comparison bug) and the
   exact UI overlaps.
3. Look at the snapshot's `events` and `chat`: a large `PLAYER_CAMPING` /
   `LOGOUT_CANCEL` count revealed the idle-logout loop; `SMSG_GROUP_DECLINE` in
   the fixture log revealed the hidden invite.
4. Reproduce in an offline spec, fix, then re-run live once.
5. Read the SDK source (`.forge-tools/wowcontrol-sdk/source`) before guessing:
   it explained the pipe race and the idle loop.

## Open work

- Combat and quest fixtures.
- ForgeLootLedger 1.1 (loot tracking from RaidSync): the real `GiveMasterLoot`
  handout, its deDE `LOOT_ITEM_SELF` confirmation ("Ihr erhaltet Beute: ..."),
  the corpse's creature ID (15209) and the RS2 export passed live on 2026-10-16
  (run `83b3795d931f`). The roll log (counted, re-roll and 1-1000 rows) passed
  live in run `cf79987a1d8a`; the CLEAR button itself is verified offline only.
  The plan starts with `/forgeloot newraid confirm`,
  because SavedVariables persist between live runs and old awards would
  otherwise satisfy the checks. Two more plans cover the bot:
  `ForgeLootLedger-peer-acceptance.json` (the bot wins; run `b2b299f6e36e`) and
  `ForgeLootLedger-trade-acceptance.json` (held item traded to the bot; run
  `b1b2079d8755`). Still offline only: ties, CLEAR, trades between other
  players. RS2 uses `;` because `|` starts EditBox escapes (`|T`, `|c`); the
  `;` export renders cleanly in the live screenshot.
- Offline text widths are estimates (0.6 em per character); confirm UI with a
  live screenshot.
- `flake.nix` gained `python.pkgs.lupa`; not yet built with Nix.
- `projects/` is git-ignored: new addons there are local only until moved to `examples/` or their own repo.
