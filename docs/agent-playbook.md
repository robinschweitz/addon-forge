# Agent playbook: building 3.3.5a addons that actually work

Hard-won knowledge from building and live-verifying
[`examples/RaidLedger`](../examples/RaidLedger) (October 2026), the reference addon:
its specs and acceptance plan show every technique below in use. Read this before creating, repairing or testing an addon, and
before changing the Forge test pipeline. Facts here were observed on the real
isolated test client (German `deDE`, build 12340) unless marked otherwise.

## The loop that works

1. `forge new Name` (or edit `projects/Name/`). Lua 5.1, `## Interface: 30300`.
2. `forge check projects/Name` until clean. "unknown global" = almost always a
   hallucinated or post-Wrath API; ask `forge api lookup NAME` / `Widget:Method`.
   It also answers event names, and when `.forge-tools/milkyway-codex/` holds
   the [MilkyWay Codex](https://github.com/suprsokr/milkyway-codex-mcp) JSON
   data (copied from its `src/data/`; no licence, so never commit it) it adds a
   `reference` with signatures, return values and event payloads. Existence
   still comes from the client dump; the Codex `protected` flags are wrong for
   3.3.5a (CalendarAddEvent, SendChatMessage) and are not used.
3. Write offline specs in `projects/Name/tests/*.spec.lua` **before** fixing a
   bug: reproduce it as a failing spec, then fix, then watch it pass.
4. `forge spec projects/Name` until green, including `forge.layoutIssues(frame)`
   for any UI. For a window that real data fills (a 25-player raid, long German
   names, many items), add a spec that sets that data up and calls
   `forge.sketch("name", frame)`: it saves `.forge-runs/sketches/Addon-name.svg`,
   a drawing of the frame (backdrops, colors, text) to look at before the
   live run. Estimated fonts, no texture files: confirm with a live screenshot.
5. Write the acceptance plan with checks that observe the addon (`chat_contains`,
   `global_equals`, `frame_text_contains`, `event_fired`, `no_lua_errors`) and
   `steps` that drive it (`slash`, `roll`, `wait`, `click`, `hardware_click`).
6. Live run: close WoW, then
   `forge --config forge.local.toml agent session projects/Name-acceptance.json --approve-fixtures`.
   Use `agent session` after **any** addon change: a running client keeps the
   code it loaded at startup (`run-plan` refuses stale deploys for this reason).
   See [Who runs live sessions](#who-runs-live-sessions).
7. Read the JSON result, then the screenshot in `projects/.forge-runs/`. Fix,
   repeat. Never weaken a check; tighten one that could pass vacuously.
   SavedVariables persist between live runs: start the plan's steps from a
   known state (RaidLedger's first step is `/ledger newraid confirm`),
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
2. A session leaves the test client running when it ends; the next
   `agent session` closes it before deploying (FR-7.6): only processes whose
   executable is the marked copy's `Wow.exe`, never another WoW installation.
   A client that ignores the close request for 20 s is ended.
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
- `RandomRoll(low, high)` is not protected: an addon may call it from a button
  click and from an `OnUpdate` timer without any hardware event
  (RaidWishlist's prompt and auto-roll, runs `e0284c58e3ab`, `bb9f6ee936ce`).
- **Calendar** (runs `08455f4dff39`, `51bc301bfff3`): `CalendarEventInvite`
  on a new event works from a timer, but the server resolves each name first,
  so invites are listed a moment later (`CalendarEventGetNumInvites`).
  `CalendarAddEvent` from a timer is `ADDON_ACTION_BLOCKED`: it needs a real
  click or key press, which `click` steps (SDK `lua.evaluate`) are not. A
  `hardware_click` step on the button did it: the server confirmed the event
  with its one invite (run `f1e7af99ab2b`).
  `CalendarSetAbsMonth` fires `CALENDAR_UPDATE_EVENT_LIST` synchronously, so
  never read the list from that event's handler (C stack overflow).
- Lua 5.1 drops unknown escapes: `"Interface\ChatFrame"` written with single
  backslashes becomes `InterfaceChatFrame`, a missing (invisible) texture.
- `SendAddonMessage` to PARTY/RAID also arrives at the sender as
  `CHAT_MSG_ADDON`, so two cooperating addons (ledger and wishlist) can be
  tested on one client.
- Two addon windows in the same strata interleave: one window's child panes
  draw through the other. Give windows `SetToplevel(true)` and `Raise()` them
  on show; put popups that must stay visible in a higher strata
  (`FULLSCREEN_DIALOG`). Offline `layoutIssues` checks one addon only, so
  look at a live screenshot when addons share the screen.

## WoWControlSDK facts (verified live)

- SDK `lua.evaluate` may call protected `TargetUnit`, but opening loot
  (`InteractUnit`) needs a hardware event: bind `INTERACTTARGET` to a fixed
  unbound chord, press it once with `SendInput`, restore the binding.
- The `hardware_click` step uses the same trick for any registered frame:
  `SetBindingClick("CTRL-SHIFT-F10", name, "LeftButton")`, one `SendInput`
  press, then the previous binding back. Binding clicks find the frame by its
  global name, so create it with that name (the step requires
  `frame:GetName()` and `_G[name]` to match). The step hooks `OnClick` to prove
  the press arrived (`not_clicked` otherwise).
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
  `"15 seconds left"`. Use distinctive text (`" - 5 seconds left."`).
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
- The loot fixture's creature is a persistent `.npc add` spawn. The
  AzerothGhost cleanup deletes its DB row, then sends `.npc delete` without
  waiting; when that missed, the corpse stayed in the running world, respawned
  alive and killed the Nordhaintal guards (2026-10-18). The fixture now deletes
  the live corpse itself and waits until the bot sees it vanish
  (`loot-fixture.log`: "removed from the world"). A clean `creature` table
  plus a worldserver restart removes any leftover.
- Dead test characters cannot loot: on 2026-10-20 both characters stood at
  1 HP (dead) in Nordhaintal, killed by a leftover creature, and every plan
  failed at "loot did not open". The fixture now sends `.revive` for the
  graphical and the member character first (a living one is left as is), and
  again after the kill: the level-60 elite templar spawns next to the
  level-10 characters and once killed one before `.damage` landed (run
  `905688594b78`, the "Ihr seid gestorben" popup in `loot-open.png`).
- Windows' foreground lock: `SetForegroundWindow` silently fails when the
  calling process does not own the foreground. In a batch of sessions the
  first client got focus, the second never did ("WoW is not the active
  window", twice on 2026-10-20). `focus` now retries with
  `AttachThreadInput` to the foreground thread; the next batch of five passed.
- A session's final screenshot (`RUN_ID.png`) shows the end state; use
  `screenshot` steps for anything in between.

## Offline emulation vs. the client (decompiled 12340 client)

`headless/wow.lua` was audited on 2026-10-20 against a C++ decompilation of the
12340 client ([SatyPardus/wowdecomp](https://github.com/SatyPardus/wowdecomp),
cloned locally to `.forge-tools/wowdecomp`; used as reference only: never copy
its code here). Function names below are the client's. The probe addon
`tests/emulation/ClientFidelity` holds a spec for every fixed point; 23 of its
28 tests failed on the old emulator.

`forge api lookup` uses that optional local checkout too: it indexes the
client's native Lua registrations, widget method tables and event list, and
returns only the API name plus its source location/symbol. The real-client dump
remains authoritative for FrameXML and runtime globals that the native source
does not register.

Fixed in the emulator:
- **SavedVariables** (`LoadAddOn`, `FrameScript_LoadVariables`): the saved file
  runs after the addon's files, in a scratch table, and only the values it set
  are copied into globals. A variable never saved, or saved as nil, keeps what
  the addon's file assigned (`MyDB = MyDB or {}` at file scope survives). The
  emulator used to overwrite it with nil.
- **Login vs. /reload order** (`CGGameUI::InitializeFrameXML`,
  `LoadAccountVariables`, `AccountVariablesLoadedCallback`): at login
  ADDON_LOADED, PLAYER_LOGIN, PLAYER_ENTERING_WORLD, then VARIABLES_LOADED when
  the account data arrives. On /reload the account data is cached, so
  VARIABLES_LOADED fires *before* PLAYER_LOGIN. PLAYER_LOGIN fires on every
  reload (`m_loggingIn` is set in `InitializeFrameXML`). Leaving goes
  PLAYER_LEAVING_WORLD (`LeaveWorld`), then PLAYER_LOGOUT, then the
  SavedVariables are written (`CGGameUI::Shutdown`).
- **OnShow/OnHide follow visibility** (`CSimpleFrame::ShowThis`/`HideThis`,
  `SetParent`): `Show()` under a hidden parent runs no OnShow; when the parent
  appears, its shown children run OnShow *before* the parent's own. Hiding runs
  the children's OnHide first; already-hidden children stay quiet.
  `SetParent` on a visible frame runs OnHide, then OnShow if the new parent is
  visible.
- **Text** (`CSimpleFontString::SetText`, `LanguageProcess`): `GetText()` is nil
  for empty text; numbers become text, other types (`true`, tables) clear it;
  `|4one:many;` is resolved at SetText (`"3 |4item:items;"` reads back as
  `"3 items"`, plural rule by locale), colour/link escapes are kept;
  `SetText` on a FontString without a font is an error ("Font not set":
  `CreateFontString(nil, "OVERLAY")` with no template or `SetFontObject`). A
  plain `Button` has no font string until its first non-empty `SetText`
  (`GetFontString()` is nil); `EditBox:SetText(nil)` is a usage error.
- **Event dispatch** (`FrameScript_SignalEvent`): listeners run in registration
  order; a frame registered during a dispatch waits for the next signal (this
  already matched); a frame **unregistered** during the dispatch is skipped for
  the rest of it (the emulator still delivered). `RegisterEvent` with a name the
  client lacks does nothing; the emulator now ignores the names in
  `wowapi.MODERN_EVENTS` (checked against the client's event table) and warns.
  RaidLedger's `LOOT_READY` registration is such a dead one (harmless:
  `LOOT_OPENED` does the work).
- **OnUpdate** (`CSimpleTop::OnLayerUpdate`, `CFrameStrataNode::OnLayerUpdate`):
  one elapsed value per frame for every visible frame (matched). A frame shown
  during the pass waits for the next frame; one hidden during it is skipped.
- **ScrollFrame** (`CSimpleScrollFrame`): its vertical range is recalculated on
  the next visible layer update; `SetVerticalScroll` keeps out-of-range offsets
  rather than clamping them.
- **SendAddonMessage** (`Script_SendAddonMessage`): type defaults to PARTY;
  only PARTY, RAID, GUILD, BATTLEGROUND, WHISPER (any case), anything else
  errors "Unknown addon chat type"; RAID outside a raid goes to PARTY; PARTY
  without a party is **dropped silently** (an offline spec that forgot
  `forge.party` used to see the message); WHISPER needs a target; prefix and
  text are joined as `prefix<TAB>text` (up to 2999 bytes in the client), and the
  receiver splits at the first tab, so a tab in the prefix moves into the
  message. CHAT_MSG_ADDON args: prefix, message, channel (PARTY, RAID, GUILD,
  WHISPER, BATTLEGROUND), sender.
- **Protected actions** (`CGGameUI::CanPerformAction`, `ShowBlockedActionFeedback`).
  Addon code is always tainted. Three kinds, each refused with
  ADDON_ACTION_BLOCKED (or ADDON_ACTION_FORBIDDEN) `(addonName, "Func()")`:
  - *hardware event needed*: AcceptTrade, CancelTradeAccept, CalendarAddEvent,
    CalendarUpdateEvent, PlaceAuctionBid, CancelAuction, AcceptProposal,
    SearchLFGJoin/Leave, AcceptBattlefieldPort, and ReloadUI (`CGGameUI::Reload`).
    The hardware flag is set only around a button's OnClick from a real mouse
    click or key binding (`CSimpleButton::OnLayerMouseDown/Up`, which is what a
    `hardware_click` step uses) and an edit box's OnEnterPressed from the Enter
    key (`CSimpleEditBox`). So a slash command *typed into chat* may call them;
    timers, `Button:Click()`, plan `click`/`slash` steps may not.
  - *out of combat only*: SetRaidSubgroup, SwapRaidSubgroup, macro and binding
    changes, action bar pickups, item equipping.
  - *never from an addon*: TargetUnit (`CGGameUI::Target`), movement and
    camera functions, RunMacro, SpellStopCasting, SpellTargetUnit.
  Offline: `forge.click`/`forge.slash`/timers are no hardware event;
  `forge.hardwareClick(frame)`, `forge.clickText(text, nil, {hardware = true})`,
  `forge.slash(text, {hardware = true})` and `forge.press(box, "ENTER")` are.
  `forge.stub` of a guarded function keeps the guard. RaidLedger's calendar
  spec stubbed CalendarAddEvent and pressed CREATE EVENT with a plain click; it
  passed only because the stub bypassed the rule. It now uses a hardware click
  (as its live plan's `hardware_click` does) and a typed `/ledger calendar`.

- **Size and scale** (`CLayoutFrame::SetWidth`/`Resize`/`OnFrameResize`,
  `SetLayoutScale`, `Script_StartSizing`, 2026-10-24; probe spec `size`):
  `OnSizeChanged` runs in the next layout pass, not inside `SetWidth`, and
  only when the size changed (the first time when the rect first resolves,
  and again after `SetScale`). `GetWidth` of a frame sized only by two
  anchors is the anchored width (the emulator used to say 0). `StartSizing`
  errors "Frame X is not resizable" without `SetResizable(true)`, and
  `StartMoving` "is not movable". `SetScale` used to be ignored offline; now
  rects are screen pixels, `GetLeft`/`GetWidth` stay in the frame's own
  units. `forge.drag(grip, dx, dy)` plays a mouse drag on a resize grip or a
  movable frame. The scale is a 32-bit float: `SetScale(1.3)` reads back as
  `1.2999999523163`, so save the scale you computed, never `GetScale()`
  (RaidWishlist's live run `f048f689a0a9` failed on exactly that).

Second pass (2026-10-20, the APIs the project addons use; probe specs
`chat`, `group`, `world`, `calendar`):
- **Chat event payload** (`SendChatEvent`): every CHAT_MSG_* has 13 arguments:
  text, sender, language, channel string, target, flags, zone channel ID,
  channel number, channel name, (unused), line ID, sender GUID ("0x" + 16 hex
  digits, "" for system lines), presence ID. The emulator used to pass only the
  text. `forge.chatEvent(event, text, sender, opts)` sends a full one.
- **RandomRoll** (`Script_RandomRoll`): both bounds required (strings or
  numbers; `RandomRoll(100)` is a usage error), nothing is sent for an empty
  or reversed range or a maximum above 1000000, and the result line comes
  back from the server, so it arrives **on the next frame**, never inside the
  call. Deathroll's and FortuneCookie's specs (projects/, local) call
  `RandomRoll` or press ROLL and read the result at once: they passed only
  because the emulator answered synchronously. Each such step needs a
  `forge.advance(0.05)` before the check; the addons themselves are fine.
- **SendChatMessage** (`Script_SendChatMessage`, `ChatParserParseText`,
  `TruncateNewLines`): SAY by default; unknown types error; `%t`/`%n` become
  the target's name (else "<no target>") and `%f` the focus's, so "50%target"
  sends the target's name; text is cut at 255 bytes and at the first line
  break (`\n`, `\r`, or a literal `\n`/`|n`); a `|` must start `||` or
  `|c...|r` (anything else, e.g. `|T` textures, is a Lua error; an unclosed
  `|c` cuts the text). PARTY outside a group and RAID outside a raid send
  nothing and print ERR_NOT_IN_GROUP / ERR_NOT_IN_RAID as a system line.
- **Groups**: `GetRaidRosterInfo` returns 14 values, `nil, 0, 1, 1, nil...` for
  an index outside the raid, PLAYER_OFFLINE as an offline member's zone.
  `IsRaidLeader` is true for the party leader too (it compares with the group
  leader); `IsRaidOfficer` means raid rank 1+. `ConvertToRaid` is refused by
  the client itself unless the player leads a party with members and is level
  10+ (the live "below level 10" finding); the server converts on the next
  frame. `InviteUnit` errors on names over 48 bytes.
- **Loot**: an item that leaves the loot window (`GiveMasterLoot`,
  `LootSlot`) fires LOOT_SLOT_CLEARED(slot). `GetItemInfo` returns nothing for
  items not in the cache and errors on a non-string/number.
- **Bags** (`Script_GetContainerNumSlots`/`ItemLink`): backpack 16 slots, bank
  28, keyring 32, missing bags 0; `forge.bag` fills one. **Guild**
  (`Script_GetNumGuildMembers`, `Script_GetGuildRosterInfo`): online members
  unless `GetNumGuildMembers(true)` or show-offline; 11 values per member,
  `nil, nil, 0, 0, ..., "", nil` past the end; `GuildRoster()` answers with
  GUILD_ROSTER_UPDATE on the next frame. `forge.guild{...}` sets it up.
- **Calendar** (`CGCalendar::Invite`, `CGCalendar::AddEvent`,
  `CGCalendarEvent::Invite`, `CreatePlayerEvent`): a new event has the creator
  as invite 1. While an invite or new event waits for the server,
  CALENDAR_ACTION_PENDING(true) and further invites/adds are ignored. The
  client allows **one invite per 2 seconds** and one new event per 5 seconds;
  faster calls fire CALENDAR_UPDATE_ERROR (`CALENDAR_ERROR_INVITE_THROTTLED`,
  `..._EVENT_THROTTLED`). 100 invites max; names are case-fixed; an existing
  invite errors. `CalendarSetAbsMonth` fires CALENDAR_UPDATE_EVENT_LIST
  synchronously (matches the live finding). **RaidLedger** invites every
  0.25 s (`CALENDAR_INVITE_DELAY`), so with two or more names all but the
  first are throttled in the real client; only a one-invite event has been
  verified live. Its calendar spec stubs the calendar, so it does not see this.
  The throttle-bypass CVar's registration is not ported in the decompilation,
  so its name and default are unconfirmed; a live run with three names would
  settle it.
- **ColorSelect** (`CSimpleColorSelect`): `SetColorRGB` runs OnColorSelect at
  once; `ColorPickerFrame` exists (hidden).
- **Event payloads**: TRADE_PLAYER_ITEM_CHANGED(slot), TRADE_ACCEPT_UPDATE
  (player, target), LOOT_OPENED(autoLoot 0/1), RAID_ROSTER_UPDATE (no
  arguments), UI_INFO_MESSAGE / UI_ERROR_MESSAGE (the message text),
  PARTY_INVITE_REQUEST(name), BAG_UPDATE(bag). Third-party event lists get
  several of these wrong for 3.3.5a (an item link on
  TRADE_PLAYER_ITEM_CHANGED, a reason on RAID_ROSTER_UPDATE, a number on
  UI_INFO_MESSAGE); trust the client.

Not changed (checked, or unclear):
- GameTooltip's TextLeft/TextRight lines come from the FrameXML template
  (not in the decompilation; the client only adds lines beyond the template's).
  The emulator creates lines on demand, and `AddDoubleLine` still joins both
  sides into the left line.
- `UnitName` for a group member's *name* (not unit token) and ColorSelect's
  colour rounding (the client stores HSV and returns 8-bit RGB) are not
  modelled exactly.
- The server's replies to `InviteUnit` (system lines, roster events) are left
  to specs (`forge.party`/`forge.raid`).
- RandomRoll and SendChatMessage are not protected (`CanPerformAction(10)` is
  allowed), matching the live finding above.
- Frame-level protection (Show/Hide/SetPoint of secure frames in combat,
  `CScriptRegion::ProtectedFunctionsAllowed`) is not emulated: no emulated
  frame is protected.
- The 255-byte addon message limit is server-side; the client sends up to 2999
  bytes. Not modelled offline; keep messages short.
- The server echoes PARTY/RAID addon messages to the sender (see above); the
  emulator does not, so specs fire CHAT_MSG_ADDON themselves.
- OnUpdate order (strata, then level, then registration) and the order of
  regions before child frames in OnShow are approximated by creation order.

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
- RaidLedger 1.1 (loot tracking from RaidSync): the real `GiveMasterLoot`
  handout, its deDE `LOOT_ITEM_SELF` confirmation ("Ihr erhaltet Beute: ..."),
  the corpse's creature ID (15209) and the RS2 export passed live on 2026-10-16
  (run `83b3795d931f`). The roll log (counted, re-roll and 1-1000 rows) passed
  live in run `cf79987a1d8a`; the CLEAR button itself is verified offline only.
  The plan starts with `/ledger newraid confirm`,
  because SavedVariables persist between live runs and old awards would
  otherwise satisfy the checks. Two more plans cover the bot:
  `RaidLedger-peer-acceptance.json` (the bot wins; run `b2b299f6e36e`) and
  `RaidLedger-trade-acceptance.json` (held item traded to the bot; run
  `b1b2079d8755`). Still offline only: ties, CLEAR, trades between other
  players. RS2 uses `;` because `|` starts EditBox escapes (`|T`, `|c`); the
  `;` export renders cleanly in the live screenshot.
- RaidLedger 1.2 (MS/OS rolls, points, item tally, announcements,
  tooltips, shared ledger) passed all three plans live on 2026-10-16: main
  `6c33864f0d6e` (MS roll, award announcement), peer `5b7500e30d45` (the bot's
  `/rnd 99` wins as off spec; the client received its own `CHAT_MSG_ADDON`
  party echo), trade `f834a1decc19` (a 31-130 enhanced roll counts as main
  spec; the trade is announced). Still offline only: a second addon user
  receiving the shared ledger (the bot does not run addons), the tally deciding
  a live roll, tooltips (no hover step).
- RaidWishlist 1.0 (members' wishlist, roll prompt, auto-roll, who got
  what) with RaidLedger 1.3 (shares roll starts as `S` messages) passed
  live on 2026-10-16: prompt `e0284c58e3ab`, auto-roll `bb9f6ee936ce`; the
  ledger's main plan still passes (`62c5291c833d`). Plans list the ledger in
  `companions` and paste the wishlist with a `paste` step. Still offline only:
  a member on a second client, tie-break auto-rolls.
- **Two real clients** (2026-10-16): `"member"` plans start a second injected
  client for the FORGEMEMBER account (character Raidmember). The stock SDK
  could not do this: every DLL served the same pipe name and the second
  client's pipe never answered (735 of 735 probe connections reached the first
  client), and its window lookup compared a thread ID with the process ID.
  The Forge SDK build (`tools/wowcontrol-sdk/forge-sdk.patch`) serves
  per-process pipes; the injector then runs with `--no-pipe --wait`. Worldserver
  console account creation needs a TTY that `docker attach` lacks when run by
  an agent; `forge local-realm create-member` uses the AzerothGhost SRP6
  helper instead and never touches an existing account. First two-player run
  passed 13/13 (`e79dce3d73c2` lead, `c92f8b278d93` member): the member's
  wishlist prompt, a 31-130 roll from the member's client, the master-loot
  handout to the member, and the member's "who got what" list over addon
  messages. A new character shows the WoW welcome tutorial. By default every
  test-client addon loads on both clients; `"member_addons"` limits the
  member to e.g. RaidWishlist (written to the character's AddOns.txt,
  verified live: `SlashCmdList.RAIDLEDGER` is nil there, run `a70a09025c67`).
- RaidLedger 1.4 / RaidWishlist 1.1 (open items: PARK, roll later,
  OPEN ITEMS list) passed live: parking flow `b0ba9606fdba` (PARK with the
  master looter, later ROLL, wishlist prompt during the later roll, winner on
  the same award); regressions main `dc2c24cc790f`, trade `bd9a88a6b620`,
  wishlist prompt `af15dd7a3008`. Still offline only: parking with another
  raider (the fixture bot cannot receive an item it did not roll for in the
  plan), and the open-list scenarios beyond the master looter.
- RaidLedger 1.5 / RaidWishlist 1.2 follow the guild website
  (robinschweitz/raid-website, ADR 070): enhanced main spec is any 1+X..100+X
  with X = min(EP, 50) (no steps of 10); RS2 lines end with the roll winner;
  the wishlist imports WL2 (EP balance in the header, `ms|os;enhanced 0/1` per
  item) and lowers its balance copy after an enhanced win. Specs cover this
  (`tests/enhanced.spec.lua`); the live plans use WL2. Two-player plan passed
  live on WL2 (run `b9c26fa82e6a`, member `8fff25e7c5dd`: 30 EP -> 31-130).
- RaidLedger 1.6 / RaidWishlist 1.3: German texts in deDE clients
  (`Locales.lua`, English keys are the fallback), DE/BANK recipients (RS2
  states `disenchanted`/`bank`, counted for nobody), members share wishlists
  with the ledger (`W`/`WQ` messages; WL count per drop, `[WL #rank]` on
  rollers), minimap button and auto-open on a wished roll. The live plans now
  expect German addon text. Passed live: two-player `0df172acedcd` (member
  `d6a6737428fc`: wishlist reached the lead's ledger, German import message,
  minimap button, window reopened by the roll) and main `c42c8699a9a9`
  (German announcements). Still offline only: DE/BANK (the fixture drops one
  item), the English fallback in a non-German client, dragging the minimap
  button, a raid of many members sharing at once.
- RaidLedger 2.0 replaces RaidSync (`Raid.lua`: invites, group sort,
  attendance; `;`-separated `RS2;INV` / `RS2;ROSTER`). Passed live with the
  new `raid_lead` fixture (`81bb5148cbe4`, member `0f9585f5fe94`): real
  `InviteUnit`, `ConvertToRaid`, the deDE "nicht auffindbar" message, the sort
  and the attendance export. Lessons: the master_loot bot leads the party, so
  plans that invite need `raid_lead`; a party below level 10 cannot become a
  raid and the server ignores `ConvertToRaid` silently (RaidSync then looped
  forever; the ledger now gives up after three tries and invites into the
  party). Still offline only: more than four invites, declines, the bench, a
  real group swap (two players never need one).
- Renamed to RaidLedger (`/ledger`) and RaidWishlist (`/wish`) before release
  (no saved-data migration). Passed live after the rename: two-player
  `1b1ccbcd9cc7`, raid setup `be409e5ef19a`. The old deploy folders were moved
  to the test client's `Interface/AddOns/archive`.
- The `boe_loot` fixture option (`["master_loot", "boe_loot"]`) kills The Rake
  (5807, stock 100% Lionfur Armor 17922, uncommon BoE) instead of the Crimson
  Templar; no realm change. RaidLedger's free BoE roll passed live on it
  (run `88000397b237`): a normal roll without takers, the tooltip-scanned BoE
  popup (its JETZT button is the bridge frame `RaidLedgerFreeRollNow`, since
  the popup can land in any StaticPopup slot), the free roll and the `boe`
  export. The 3.3.5a `StaticPopup_Show` returns the dialog frame.
- Passes and roll corrections (master looter only; right-click a roll in the
  roll list under the items, or `/ledger pass|count`) passed live in runs
  `52b16cd1e4ce` and `7f6b5bfccbc8` (with the roll list). A pass in a given-out
  award's roll log re-awards it to the next-best roll (the bot's off-spec
  roll): `RaidLedger-pass-award-acceptance.json`, run `d04ac8ef909e`
  (`RaidLedger-pass-acceptance.json`): a corrected enhanced roll, a pass after
  the winner was announced, the bot's off-spec roll winning instead. The
  right-click menu and the points popup are verified offline only (plan
  `click` steps press the left button).
- Offline text widths are estimates (0.6 em per character); confirm UI with a
  live screenshot.
- `flake.nix` gained `python.pkgs.lupa`; not yet built with Nix.
- RaidLedger 2.4.0 / RaidWishlist 1.5.0 (first real raid, 2026-10-19): only an
  award's recorder announces it (a second ledger announced every item again,
  as `item:50667` when uncached); pending wins count in the tally and the
  "so far" text names both specs; "nobody wanted it"; group-loot wins
  ("X won: ...") recorded without a spec by one ledger; identical tokens from
  one corpse are one "3x" roll; editor list (SETTINGS, `/ledger allow|deny`,
  shared as `E`) and addon users (`HQ`/`H`/`HW`); tooltips on every control
  (`tests/tooltips.spec.lua` walks all panels). The main, peer and trade plans
  passed live on 2.4.0 (runs `e53b59b2ca15`, `f01bd8b9796f`, `a0b4a748e3b0`; the
  new "bisher 0 MS / 0 OS Items" text, one announcement per award). `RaidLedger-tally-acceptance.json` rolls twice
  (corpse, then `/ledger roll` on the same item from the bags) and proves the
  second roll counts the first award: "bisher 1 MS / 0 OS Items", roll-log
  tally 1, "(MS, 1 Item)" in the window, `/ledger tally` 2 (run
  `db6c04492d34`; a BANK tooltip shows in its screenshot). Still
  offline only: editors, addon users, group loot, token bundles (the fixture
  drops one item, no second ledger client). Lessons: the main chunk of
  `RaidLedger.lua` is at Lua's 200-local limit, so new code goes into
  `Access.lua` or `roster.*` functions; never `string.lower` a name you store
  (the emulator mangled "ä"), only compare lowered names.
- RaidLedger 2.5.0 (tabbed window: loot, awards, tally with -/+ corrections,
  raid, settings) passed six plans live on 2026-10-20: main `30f4ce5b302d`,
  open-in-loot `764e88ae7836`, park-self `384e30965603`, reassign
  `6a4c1279ef62`, tally `891eb87e3104`, peer `465b90c2022c`. A plan check on
  a renamed frame (`RaidLedgerRollHeading` -> `RaidLedgerAwardLogHeading`)
  passed every preview and only failed live: after a UI rework, grep the plans
  for every frame name the addon no longer registers. Tally corrections, the
  settings tab and the RAID tab are verified offline only.
- RaidWishlist 2.0.0 (tabs WUNSCHLISTE / OFFEN / DIESER RAID, each a
  17-row list scrolling with the mouse wheel, after the raid feedback "you
  cannot scroll down the loot") passed four plans live on 2026-10-20: prompt
  `08285cf4bb1a`, auto `ea94163bf914`, open `1562a0ed78df`, two-player
  `3a5b72212252`. Scrolling itself is verified offline only
  (`tests/scrolling.spec.lua`, 30 wishes / 25 open / 40 awards); plan `click`
  steps cannot turn the mouse wheel. RaidLedger's tally tab is now SPIELER.
- RaidLedger 2.6.0 (resizable, scalable window; the RAID list fills the tab,
  after the raider screenshot of 2026-10-24) passed live in run
  `f572285e0ba5` (`RaidLedger-window-acceptance.json`, no fixtures):
  `/ledger scale 70` and `130` render and save, the grip shows, the RAID tab
  lines up. Solo, the attendance EXPORT only says "Noch niemand im Raid
  gesehen" (the first run's check expected a roster and was wrong). Dragging
  the grip is verified offline only (`forge.drag`); plans have no drag step.
- RaidWishlist 2.1.0 (resizable, scalable window: grip and - / + in the
  bottom bar, `/wish scale`, `/wish reset`) passed live in run `3d2fe31cc17d`
  (`RaidWishlist-window-acceptance.json`, no fixtures). The first run
  `f048f689a0a9` failed: it saved `GetScale()`, the client's 32-bit float.
  Dragging the grip is verified offline only.
- `projects/` is git-ignored: new addons there are local only until moved to `examples/` or their own repo.
