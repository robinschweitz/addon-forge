# Autonomous addon QA on a local Windows test realm

> **Status: experimental, updated 2026-10-15.** This document describes
> commands on `main` once the verified feature branch is merged.
> Commands shown are implemented; individual subsystems are **not** all
> proven on a live game client. See [Verification status](#verification-status).

## What belongs where?

- **OpenCode (or another agent):** reads [AGENTS.md](../AGENTS.md) and
  creates/revises addon code, offline specs and independent acceptance plans,
  calling Forge through the `addon-forge` MCP server (`opencode.json`).
  The former `forge ai` OpenAI-compatible backend was removed.
- **Python Forge CLI:** deploys addons, guards the isolated client and Docker
  realm, launches approved fixtures, correlates reports, evaluates checks,
  archives evidence. It never executes model-generated shell/SQL commands.
- **Offline harness:** `forge check` (embedded Lua 5.1, bytecode API checks)
  and `forge spec` (headless 3.3.5a emulation) run in under a second without
  a client and gate every real-client run.
- **ForgeTestBridge (v3):** a development-only, Lua 5.1 / Interface 30300 addon
  installed in the **separate test client**; captures live UI state, chat,
  event counts, watched SavedVariables paths and Lua errors using 3.3.5a APIs.
  On Windows it returns the report as JSON through the SDK in one call; on
  Wine it writes SavedVariables on `/reload`.
- **AzerothGhost:** real protocol clients connected to the disposable local
  AzerothCore server. They are not copies of the graphical WoW executable.
- **Original WoW installation:** out of scope. Never patch `Wow.exe`, alter
  your normal Rising Gods client, or copy account credentials into git.

## One-time setup

Follow [Local realm setup](local-realm.md) for an isolated client, AzerothCore
and `forge.local.toml`. Follow [Windows testing](windows-testing.md) for
Windows dependencies and optional test-account credentials in Windows
Credential Manager for SDK login.

Minimum requirements for **server fixtures**: running, loopback-only local
AzerothCore Docker Compose with Forge-generated `.env`; Go's module-selected
toolchain 1.26+ (`go1.25.5` with `GOTOOLCHAIN=auto` is fine);
`AC_WARDEN_ENABLED=0` **only for the test worldserver**.

To configure the optional local-only Warden setting, use an existing
`docker-compose.override.yml` if present (preserve its current contents),
or create one with:

```yaml
services:
  ac-worldserver:
    environment:
      AC_WARDEN_ENABLED: "0"
```

Check `docker compose config` before restarting **only** the worldserver:

```powershell
docker compose up -d --no-deps --no-build --force-recreate ac-worldserver
docker compose logs --tail 40 ac-worldserver
```

**Never use `docker compose down -v` or delete MySQL volumes to fix a test.**

## Optional WoWControlSDK backend (experimental, Windows only)

This is the Windows automation backend (login, character entry, bridge
transport and the API dump); it does not replace ForgeTestBridge or
AzerothGhost. The external project
[WoWControlSDK](https://github.com/Zerik-Official/WoWControlSDK) controls a
real graphical WoW 3.3.5a client using a DLL and local Windows named-pipe
JSON-RPC. It provides API login, named character entry, Lua evaluation and
world queries. **We have not live-tested this backend** on the local test
copy and it should not be used on a public realm.

**Recommended:** Forge now automates acquiring and building a **pinned**
WoWControlSDK source revision. The setup command will not launch WoW, inject
a DLL, or change your Docker realm. Preview with:

```powershell
.\.venv\Scripts\forge.exe --config forge.local.toml agent wowcontrol-setup
```

Authorize a pinned Win32 Release build and, only if Git/CMake/Visual Studio
2022 C++ tools are missing, allow `winget` to install them:

```powershell
.\.venv\Scripts\forge.exe --config forge.local.toml agent wowcontrol-setup --approve-build --install-prereqs --realm-name "EXACT LOCAL REALM NAME"
```

Replace the quoted realm name with the local AzerothCore realm's actual
display name. Microsoft Visual Studio Build Tools may require elevation
or a restart; run the command again afterward if the process reports missing
prerequisites. Without `--install-prereqs`, setup only checks prerequisites
and reports missing tools (no system-wide installation). Without
`--approve-build`, setup is a read-only preview. Without a realm name
(either from `--realm-name` or an existing `wowcontrol_realm` setting)
it will build and record paths but **not switch** from the working Win32
backend. It never downloads a precompiled third-party DLL.

Forge checks out the exact upstream commit
`6cda5ac734dba8016a7ef30ae7bcad602472c1e2`
into ignored `.forge-tools/wowcontrol-sdk/source`, builds both artifacts
for **Win32/x86**, validates their PE headers, and reports SHA-256 hashes.
It refuses modified or differently sourced code on repeated runs. The
existing `forge.local.toml` is amended only with SDK settings, and its
first pre-setup copy is preserved under ignored `.forge-tools`.
Source auditing cannot be fully automated: this is third-party native
code with process-injection privileges. Run it only on a trusted, isolated
Windows desktop or disposable test VM.

You may also configure the existing local ignored
`forge.local.toml` manually (paths are illustrative):

```toml
[client]
automation_backend = "wowcontrol"
wowcontrol_injector = "C:/tools/WoWControlSDK/WowInjector.exe"
wowcontrol_dll = "C:/tools/WoWControlSDK/WoWControlSDK.dll"
wowcontrol_realm = "Your Local AzerothCore Realm"
```

If the SDK injector starts and Forge fails with `ModuleNotFoundError: No
module named 'win32file'`, the SDK build itself was successful but the
**Forge virtual environment** is missing `pywin32`. Close the isolated
test WoW client created by the injector, then install the project extras
once:

```powershell
.\\.venv\\Scripts\\python.exe -m pip install -e ".[windows]"
.\\.venv\\Scripts\\python.exe -c "import win32file; print('pywin32 OK')"
```

Retry `agent session` after verifying the separate client is closed.
Newer Forge versions fail **before injection** when this dependency is
missing. `agent wowcontrol-setup --approve-build --install-prereqs`
also installs the declared Windows Python extras when needed, not just
the C++ toolchain. It never needs to reset AzerothCore or rebuild SDK
binaries to resolve this Python error.

Preserve the existing `wow_dir`, `wine_prefix` and `[realm]` settings.
Install Windows extras once with
`.\.venv\Scripts\python.exe -m pip install -e ".[windows]"`.
The existing Windows Credential Manager test account is used; no password
is passed on the command line. WoW must be closed at startup. Use
`forge agent session examples/forge-example-scenario.json --approve-fixtures`
after previewing without `--approve-fixtures`.

Security requirements: use only the Forge-marked separate test copy.
Forge verifies the SDK pipe's server PID matches the verified WoW window
before **each RPC**. It rejects unexpected screen state, character lists,
realm configuration, unapproved RPC methods and unexpected Lua identity.
A **fresh ForgeTestBridge v2 report** must independently confirm the actual
in-world character name. Do not use SDK flags such as `--kill` or put
passwords into `--pipe-cmd`. The SDK currently creates a fixed-name
named pipe using default Windows ACLs; a malicious local process could
interfere with it, so run under a dedicated, trusted desktop login.
The injected DLL has arbitrary native-code privileges. Review upstream
source and consider a dedicated disposable Windows VM.

### SDK Lua player identity can crash WoW (observed October 2026)

On the pinned SDK build, `lua.evaluate` of `return UnitName('player')`
was associated with a native game crash, whereas `unit.get` returned the
correct character. Forge therefore **does not issue this Lua identity RPC**
during startup or `agent wowcontrol-status --player`.

Startup checks `client.getScreen` and two consecutive matching
`unit.get(player)` results. After first seeing the world, it tolerates a
transient mismatched name for up to eight seconds (the pinned SDK was observed
reporting a wrong name immediately after `client.enterWorld` and the correct
name later in the **same PID**). Persistent mismatches are refused, and SDK-only
mode never claims addon behavior passed. **This SDK check alone is not verification**:
`agent prepare` requires a fresh and correlated ForgeTestBridge v2 smoke
report with exactly the requested player name before it returns
`character_verified` and before an approved session can continue.
Never skip that independent requirement if the report is unavailable.

`agent wowcontrol-status --player` is diagnostic only; it reads the
PID-verified screen and SDK unit name without Lua calls or any credentials.
It is not evidence that an addon or identity has passed QA.

Other SDK `lua.evaluate` operations (including bridge dispatch) have
not yet been proven safe against this native crash. If the SDK still crashes,
use the existing Win32 backend and manually enter the test character before
running a correlated bridge smoke test. Do not use the SDK on a public realm.

### SDK-first observation without ForgeTestBridge (limited)

An opt-in scenario may specify `"observer": "sdk"` instead of the default
`"bridge"`. This path does **not** deploy, invoke, or inspect ForgeTestBridge.
It currently supports only `player_in_world` with `peers: 0`; all
`frame_visible`, `target_player` and `party_count_at_least` requests are
rejected at plan validation, before injection. It never calls SDK Lua.

Example scenario (place beside its addon folder):

```json
{
  "version": 1,
  "addon": "ForgeExample",
  "character": "Test",
  "peers": 0,
  "observer": "sdk",
  "checks": [{"type": "player_in_world", "value": true}]
}
```

Run preview first, then an approved session using this scenario. The outcome
is deliberately `"observed"` and `addon_verified: false`, **not** a passed
addon acceptance test. To assert addon frames, use the bridge observer until
SDK game-function Lua execution is repaired and separately validated on the
test client. This mode does not establish that an addon loaded, registered
frames or behaved correctly. The original scenario without `observer` retains
its bridge-based acceptance behavior.

### Create and run your first bridge-independent addon: ForgeClock

`examples/ForgeClock` is an actual WoW 3.3.5a addon, not a test stub.
It creates a movable clock showing server hours/minutes and local seconds.
The `/forgeclock` slash command toggles the frame; `/forgeclock show`
and `/forgeclock hide` explicitly control visibility. It does **not**
require ForgeTestBridge or SDK Lua calls.

Close the marked test WoW and run:

```powershell
.\.venv\Scripts\forge.exe --config forge.local.toml agent session examples\forge-clock-sdk-scenario.json --approve-fixtures
```

The SDK-only session stages the addon before launch and observes the named
character in the world. This does not attest to addon loading or UI behavior.
**Visually verify** the ForgeClock rectangle appears near the center of the
screen, drag it, and manually type `/forgeclock hide`, then
`/forgeclock show`. If the frame is absent, inspect AddOns on character
selection, check whether ForgeClock is enabled, and inspect WoW Lua errors.

ForgeClock provides an editable starting point. Once the native SDK's
game-function Lua execution is repaired, automated UI/frame assertions
can replace these manual UI acceptance steps.

### SDK says the test client is not on the login screen

The SDK injector reports **pipe ready** before the WoW glue UI necessarily
finishes loading. Older Forge versions did a single early screen check and
stopped with `forge: SDK client not on login screen`, without submitting
credentials. Newer Forge versions wait for **two stable** matching
`client.getScreen` observations, up to 65 seconds for the login screen and
15 seconds for character selection after `client.login`.

If the injector left your **marked test WoW** open after a failure, obtain
read-only status *before* closing it:

```powershell
.\\.venv\\Scripts\\forge.exe --config forge.local.toml agent wowcontrol-status
```

This verifies the named-pipe server PID against the expected test WoW window
and reports only `screen` (`login`, `charselect`, `world` or empty), `in_world`
and the numeric `login_state`. It sends **no credentials or Lua commands**.
Empty `screen` may mean the client is still starting; if it persists past
the timeout, inspect the visible test WoW for EULA/first-run dialogs or
compatibility problems. Forge refuses to reuse an already authenticated
unknown account or world session. It never auto-accepts legal agreements.

Close **only** the isolated test client before retrying `agent session`.
The original WoW installation, SDK build artifacts and Docker volumes do not
need rebuilding or resetting.

As in the traditional backend, reports/screenshots come from the real
client. For now, addon checks still use Forge's established chat/bridge
runner; SDK RPC is used for startup and identity, not for executing model
supplied arbitrary Lua. This preserves independent acceptance evidence.
A fully scriptable policy-checked Lua/actions facade remains future work.

## The offline loop (no client needed)

Every addon change should pass these before any real-client run; `agent
run-plan` re-runs both and stops early if either fails.

```powershell
.\.venv\Scripts\forge.exe new RaidTimer                 # addon + tests/RaidTimer.spec.lua + RaidTimer-acceptance.json
.\.venv\Scripts\forge.exe check projects\RaidTimer      # Lua 5.1 syntax, 3.3.5a API use, accidental globals
.\.venv\Scripts\forge.exe spec projects\RaidTimer       # headless 3.3.5a emulation + offline specs
.\.venv\Scripts\forge.exe api lookup IsInGroup Button:SetTextColor
```

`forge check` knows a built-in list of APIs that are definitely absent from
3.3.5a. For complete coverage, dump the real client's globals and widget
methods once (read-only Lua over the SDK, client in world, ideally with only
ForgeTestBridge enabled):

```powershell
.\.venv\Scripts\forge.exe --config forge.local.toml api dump
```

The list is written to `wow/api/globals-30300.txt` (git-ignored, local data).
Afterwards unknown globals are flagged by `check`, and the offline harness
makes calls to widget methods the real widget lacks fail like the client does.

Offline results are **fast feedback, not acceptance**: the emulation reports
what it does not model (`not emulated offline` notes), and only the bridge
snapshot from the real client can pass a plan.

## Daily Windows workflow

From the checkout root in native Windows PowerShell:

```powershell
git pull --ff-only
.\.venv\Scripts\forge.exe --config forge.local.toml agent capabilities
```

If WoW is **closed**, deploy the current bridge and launch your marked,
separate test client:

```powershell
.\.venv\Scripts\forge.exe --config forge.local.toml agent prepare --start-client
```

With the WoWControlSDK backend and a saved Credential Manager test account,
preparation can also log in and enter the world through the SDK, then
verify the in-world identity with a correlated bridge report:

```powershell
.\.venv\Scripts\forge.exe --config forge.local.toml agent prepare --start-client --login --enter-character Test
```

It reports `character_verified` only after that proof, and otherwise aborts.
Credentials are passed over the PID-verified SDK pipe, never typed or put on
a command line. The former pixel-calibrated keyboard login and character
selection were removed. If the game is already running, `agent prepare` will
not replace its loaded Lua modules; to load new addon files or a changed
bridge, close/restart the test client before running new tests.

### Single-command addon QA session (experimental)

With the test WoW client closed:

```powershell
.\.venv\Scripts\forge.exe --config forge.local.toml agent session projects\RaidTimer-acceptance.json --approve-fixtures
```

This stages the addon before client startup, launches the isolated test copy
through the SDK, logs in, enters the plan's character, independently verifies
the in-game identity and runs the acceptance plan. A preview is available by
omitting `--approve-fixtures`. It refuses to run when test WoW is already open.

## Quick regression: real UI assertions with no new server players

Edit `examples/forge-example-scenario.json` and set `character` to the
local **character name** (e.g. `Test`, not the account login).
The bundled plan has `peers: 0` and checks:

```json
{
  "version": 1,
  "addon": "ForgeExample",
  "character": "Test",
  "peers": 0,
  "checks": [
    {"type": "player_in_world", "value": true},
    {"type": "frame_visible", "value": "ForgeExampleFrame"}
  ]
}
```

Deploy `examples/ForgeExample` while WoW is closed if it is not already
installed/enabled; you can also use `forge deploy examples/ForgeExample`.
After entering the world:

```powershell
.\.venv\Scripts\forge.exe --config forge.local.toml agent run-plan examples\forge-example-scenario.json
.\.venv\Scripts\forge.exe --config forge.local.toml agent run-plan examples\forge-example-scenario.json --approve-fixtures
```

The first command is a **read-only preview**. The approved command checks
sources, runs the offline specs, deploys the addon and bridge, runs a
correlated in-game smoke suite, receives the bridge v3 report, and evaluates
the independent JSON checks. The approval flag also authorizes server fixture
mutations when `peers > 0`. It doesn't automatically turn on a disabled
addon or restart an already-running WoW process.

Reports/screenshot evidence go into `examples\.forge-runs`.

### Plan check reference

| Check | Keys | Passes when the bridge snapshot shows |
| --- | --- | --- |
| `player_in_world` | `value: true` | the player unit exists |
| `frame_visible` | `value: "FrameName"` | the registered frame is shown |
| `frame_text_contains` | `frame`, `value` | the registered frame/FontString text contains `value` |
| `global_equals` | `path`, `value` | a dotted global path (e.g. `MyDB.history.1.item`) equals a string/number/boolean/null |
| `chat_contains` | `value` | a recent default-chat line contains `value` |
| `event_fired` | `value: "EVENT_NAME"` | the event fired at least once since the bridge loaded |
| `no_lua_errors` | `value: true` | the bridge captured no Lua errors |
| `party_count_at_least` | `value: 0-4` | the GUI player's party size |
| `target_player` | `value: true` (needs `peers`) | the target is a player |

`"steps"` act in the real client after fixtures and before the bridge suite
(bridge observer only; at most 20 steps and 180 s of waits). Each type maps to
one fixed SDK action:

| Step | Value | Action |
| --- | --- | --- |
| `slash` | `"/myaddon start"` | Runs one of **the addon's own** slash commands (checked against its `SLASH_*` definitions) |
| `roll` | `[low, high]` | `RandomRoll(low, high)` as the test character (a real server `/rnd`) |
| `wait` | seconds (≤ 60) | Lets timers and server messages arrive |
| `click` | `"FrameName"` | Clicks a visible frame the addon registered with `ForgeTestBridge:RegisterFrame` |
| `hardware_click` | `"FrameName"` | Clicks a visible registered frame with a **real key press**: binds the fixed chord `CTRL-SHIFT-F10` to `CLICK FrameName:LeftButton`, presses it with `SendInput` in the WoW window, waits for the frame's `OnClick`, then restores the binding. For functions that refuse Lua calls (`ADDON_ACTION_BLOCKED`, e.g. `CalendarAddEvent`). The frame needs that global name (`CreateFrame("Button", "FrameName", ...)`); nobody may type while it runs |
| `paste` | `["EditBoxName", "text"]` | Pastes text (printable ASCII and newlines, no `\|`, up to 1000 characters) into a visible EditBox the addon registered, as a user pressing Ctrl+V would |
| `screenshot` | `"name"` | Saves the client window as `.forge-runs/step-name.png` at that moment |
| `peer_roll` | `[low, high]` | The `master_loot` fixture's bot sends a real `/rnd` (`MSG_RANDOM_ROLL`), seen by the whole party |
| `peer_trade` | item ID | Trades that item from the test character's bags to the fixture's bot; both sides accept |
| `peer_say` | `[text]` or `[text, item ID]` | The fixture's bot says the text in party chat, followed by a link to the item that it builds from the realm's data. The text is 1-60 characters, starts with a letter and holds only letters, digits, spaces and `, . : ! ? ' -`, so it is never a command (SC-014) |

`"companions": ["OtherAddon"]` (up to 3, folders beside the plan) adds addons the
scenario needs as well, such as the raid lead's RaidLedger for the members'
RaidWishlist: they pass the same static and offline gates, are deployed
with the addon, steps may run their slash commands, and their Lua errors fail
the plan like the addon's own.

`"member": "Raidmember"` makes a **two-player plan**: after the main client,
the session starts a second test client and logs in that character with the
"member" credentials (create them once with `forge local-realm create-member
--account-name FORGEMEMBER --character Raidmember`). Steps and checks take an
optional `"client": "member"` to act on and observe that client; each
client's checks are judged against its own bridge snapshot, and screenshots
of it are saved as `step-NAME-member.png`. The `master_loot` fixture summons
the member next to the corpse and invites them too. `"member_addons":
["RaidWishlist"]` (some of the plan's addon and companions) makes the
member's character load only those addons, plus the test bridge, as a real
raid member would: the session writes that character's
`WTF/Account/<ACCOUNT>/<Realm>/<Character>/AddOns.txt` before it logs in. Two clients need the
Forge build of the SDK (`tools/wowcontrol-sdk/`).

Adding `"raid_lead"` (`"fixtures": ["master_loot", "raid_lead"]`) makes the
bot raise the GUI character (and the member) to level 10, which a raid needs,
and hand party leadership to the GUI character after setting master loot, so
a plan can test inviting, converting to a raid and sorting groups
(`RaidLedger-raid-setup-acceptance.json`).

Adding `"boe_loot"` (`"fixtures": ["master_loot", "boe_loot"]`) kills The
Rake (creature 5807) instead of the Crimson Templar. Its stock loot table drops
Lionfur Armor (item 17922, uncommon, binds when equipped) at 100%, so plans can
test what an addon does with a bind-on-equip drop
(`RaidLedger-boe-popup-acceptance.json`). No world data is changed: the fixture
confirms the drop with a fixed read-only query and fails if the realm's loot
table no longer guarantees it. The Rake's stock world-loot reference may add a
random extra item.

`peer_roll`, `peer_trade` and `peer_say` need `"fixtures": ["master_loot"]`. A step the
client or bot does not perform (missing command, hidden button, trade not
completed) fails the plan with `stage: "steps"` and a log of the steps run.
The bridge suite also saves a final `RUN_ID.png` after the steps.

`"fixtures": ["master_loot"]` (bridge observer, `peers: 0`) keeps a real
master-loot window open on the GUI character while the suite runs: a
temporary AzerothGhost bot invites the character, sets master loot, and kills
the fixed Crimson Templar. It targets the corpse by its client-locale name
(looked up in the world DB) with SDK `TargetUnit`, then opens it with
`InteractUnit` or one press of a temporarily bound CTRL-SHIFT-F12 interact key
(previous binding restored). **Verified live** on the deDE test client.

Because an SDK-launched client has never received real input, WoW treats it as
idle from login; the SDK blocks the resulting logout, so the idle dialog would
repeat all session and hide other dialogs (auto-declining party invites).
Forge therefore sends one press of the unbound CTRL-SHIFT-F11 chord after login
and before fixtures, after checking via the SDK that it is unbound.

## Multiplayer scenarios (test account/character state may persist)

With character `Test` already logged in and in-world:

```powershell
.\.venv\Scripts\forge.exe --config forge.local.toml agent peer-test --character Test
.\.venv\Scripts\forge.exe --config forge.local.toml agent peer-test --character Test --approve-fixtures
```

The single-peer scenario was **verified live** on the local Windows client:
an AzerothGhost Warrior appeared, the GUI client targeted it, and the
`peer_target_visible` Lua check passed with a matching v2 snapshot.
Forge sends the fixture a release signal and terminates the process after
a bounded timeout if required; test database records may remain.

Experimental bot-only party lifecycle, with **at least three** peers:

```powershell
.\.venv\Scripts\forge.exe --config forge.local.toml agent party-lifecycle --character Test --peers 3
.\.venv\Scripts\forge.exe --config forge.local.toml agent party-lifecycle --character Test --peers 3 --approve-fixtures
```

The three-peer lifecycle has now been **verified live on Windows**:
three AzerothGhost Warriors were online; the harness formed their own
party, removed one member, and Forge received a successful in-client
`peer_target_visible` assertion both before and after the departure.
Observed client reports: `61f0feae27df` (`all_peers_online`) and
`e88eaee835cd` (`peer_departed`), each with ForgeTestBridge v2 and
no missing required tests. The remaining two peer names were reported
after the departure. This verifies the **protocol fixture lifecycle and
continued graphical target observation**, not GUI group-frame behavior.
Four peers have not been separately verified live.

**Crucial:** the GUI character is *not* automatically part of that bot
party; don't claim a party-frame addon is verified just because this
fixture passes. An actual addon QA test must verify that the GUI character
joined the correct group and that UI frames/events match real game state.

## Have OpenCode build and test an addon

Run `opencode` from the Forge checkout. `AGENTS.md` gives it the
repository's addon/test contract and `opencode.json` registers the
`addon-forge` MCP server (`forge_new`, `forge_check`, `forge_spec`,
`forge_api_lookup`, `forge_plan_preview`, `forge_run_plan`). Example
instruction:

> Build a WotLK 3.3.5a party addon under projects/MyParty with offline specs,
> register observed frames with ForgeTestBridge, write a measurable
> acceptance plan beside the addon folder, and get check and spec green.
> Preview the plan. Don't weaken failing tests. Report coverage gaps.

`forge_run_plan` refuses to touch the client unless **you** started the
server with `forge mcp --allow-fixtures`; an agent cannot grant itself that
approval. Combat/quest scenarios are **not yet implemented**.

## Interpreting test outcomes

The four outcomes (`plan_only`, `passed`, `failed`, `infrastructure_error`)
are defined in [REQUIREMENTS.md](../REQUIREMENTS.md) FR-6.10. A `passed`
covers only **that specific scenario**.

On Windows the bridge report arrives as JSON from `ForgeTestBridge:RunJSON`
over the SDK; on Wine it is read from
`WTF/Account/*/SavedVariables/ForgeTestBridge.lua` after `/reload`. Python
correlates it with a random run ID and stores a JSON report and (when
available) PNG screenshot. Each snapshot can include player/target unit
data, party/raid counts, registered frame visibility/size/text, recent chat,
event counts, watched global values and captured Lua errors.

**Fail closed:** a missing/mismatched snapshot, outdated `bridgeVersion`,
stale report, wrong character, or unexpected client window must not be
silently interpreted as an addon success. Treat screenshots as supporting
evidence, not a substitute for independent assertions.

## Troubleshooting

| Symptom | Check / action |
| --- | --- |
| `Old ForgeTestBridge loaded` / `ForgeTestBridge v3 is not loaded` | Close test WoW, redeploy bridge, restart and re-enable it |
| Offline stage fails in `run-plan` | Run `forge spec projects\Addon`; fix the addon (or stub an un-emulated API in the spec), never delete the check |
| `forge test` has no report | Ensure in-world, bridge enabled and client foregroundable; see [SavedVariables troubleshooting](local-realm.md) |
| Warden preflight error | Check the local-only Docker override and actual worldserver logs |
| Wrong Go version | Run `go version` **inside** AzerothCore's `e2e` folder with `GOTOOLCHAIN=auto` |
| Peer count mismatch | Update Forge; Go and Python readiness formats must agree |
| `party-lifecycle` fails | Capture the exact stage and errors; do not reset Docker or weaken checks |
| SDK login fails | Keep the Windows session unlocked; see [SDK says the test client is not on the login screen](#sdk-says-the-test-client-is-not-on-the-login-screen) |

## Verification status

These are **user-observed local results**, not a guarantee on other machines:

| Scenario | Status | Evidence |
| --- | --- | --- |
| Real-client smoke `bridge_loaded` and addon assertion | **Verified** | Correlated in-game SavedVariables round trip |
| `ForgeExample` independent frame/player checks | **Verified** | User-provided v2 report, all checks passed; run `4d29d6d11e33` |
| One AzerothGhost peer appears and is targeted | **Verified** | User-provided peer test passed; run `60bb9bfee84b` |
| Three-peer bot party / peer departure lifecycle | **Verified live** | v2 target assertions passed at stages `61f0feae27df` and `e88eaee835cd`; bot-only group, GUI player `party.count: 0` |
| Four-peer party, GUI player membership and addon party frames | **Not verified live** | Separate membership/health/UI assertions still required |
| Static checks, offline harness, plan schema, MCP server | **Unit-tested** | Test suite; RaidLedger loot flow passes offline |
| Bridge v3 SDK JSON transport, new plan checks | **Verified live** | `ForgeExample` and `RaidLedger` plans passed (runs `e7d96f13fde3`, `448b3ba9387b`) |
| `master_loot` fixture + `agent session` | **Verified live** | deDE corpse name from the world DB, SDK `TargetUnit`, temporarily bound interact key; `LOOT_OPENED` observed, no Lua errors |
| Offline layout check (`forge.layoutIssues`) | **Unit-tested; fix confirmed live by screenshot** | Reproduced the real overlaps; text widths are estimates |
| Plan `steps` + RaidLedger roll flow | **Verified live** | Real `/rnd` 61, re-roll 3 and 1-1000 roll 600: only 61 counted, `won by Test (61)` in party chat, award saved (run `cce23000b73e`) |
| SDK idle-logout loop fix | **Verified live** | One unbound key press after login: `PLAYER_CAMPING` dropped from ~13 to 1 per session |
| `forge api dump` | **Verified live** | 33,826 globals and 2,261 widget methods; found real `Button:SetTextColor` bug offline |
| Combat, quests, buffs, items and full autonomous QA | **Not implemented** | Future capability work |

Even verified smoke tests cover only their stated conditions. Preserve
screenshots/reports locally and do not commit any private realm credentials,
full client files, or login screens.
