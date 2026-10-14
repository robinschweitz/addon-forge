# Autonomous addon QA on a local Windows test realm

> **Status: experimental, updated 2026-10-14.** This document describes
> commands on `main` once the verified feature branch is merged.
> Commands shown are implemented; individual subsystems are **not** all
> proven on a live game client. See [Verification status](#verification-status).

## What belongs where?

- **OpenCode:** reads [AGENTS.md](../AGENTS.md) and creates/revises addon code
  and independent acceptance plans. It uses your existing OpenCode provider
  setup. Native `forge ai create` and `forge ai repair` **do not** yet use
  OpenCode automatically: they require `FORGE_AI_MODEL` and
  `FORGE_AI_API_KEY` for an OpenAI-compatible endpoint.
- **Python Forge CLI:** deploys addons, guards the isolated client and Docker
  realm, launches approved fixtures, correlates reports, evaluates checks,
  archives evidence. It never executes model-generated shell/SQL commands.
- **ForgeTestBridge:** a development-only, Lua 5.1 / Interface 30300 addon
  installed in the **separate test client**; captures live UI state using
  3.3.5a APIs and writes SavedVariables on `/reload`.
- **AzerothGhost:** real protocol clients connected to the disposable local
  AzerothCore server. They are not copies of the graphical WoW executable.
- **Original WoW installation:** out of scope. Never patch `Wow.exe`, alter
  your normal Rising Gods client, or copy account credentials into git.

## One-time setup

Follow [Local realm setup](local-realm.md) for an isolated client, AzerothCore
and `forge.local.toml`. Follow [Windows testing](windows-testing.md) for
Windows dependencies, optional credentials in Windows Credential Manager
and optional calibrated visual login.

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

This is an **alternative to pixel-calibrated login**, not a replacement for
ForgeTestBridge or AzerothGhost. The external project
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

Once Windows Credential Manager and the test **login-screen calibration**
are configured, this can also submit stored local credentials:

```powershell
.\.venv\Scripts\forge.exe --config forge.local.toml agent prepare --start-client --login
```

The login path is **experimental**, requires an unlocked Windows desktop,
and refuses to enter a password unless visual checks match. It neither
confirms a successful login nor selects a realm or character.

**Still required manually:** enable newly deployed addons at character
selection if needed, select your local test character and enter the game
world. Keep the window accessible and foregroundable. If the game is already
running, `agent prepare` will not replace its loaded Lua modules.
To load new addon files or a changed bridge, close/restart the test client
before running new tests.

### Single-command addon QA session (experimental)

After one-time vault-login and selected-character calibration, close the test
WoW client and run:

```powershell
.\\.venv\\Scripts\\forge.exe --config forge.local.toml agent session examples\\forge-example-scenario.json --approve-fixtures
```

This stages the addon before client startup, launches the isolated test copy,
logs in, enters the calibrated character, independently verifies the in-game
identity and runs the requested acceptance plan. A preview is available by
omitting `--approve-fixtures`. It refuses to run when test WoW is already open.
This workflow has not yet been verified end-to-end on a real Windows desktop.

### Experimental no-click character entry (Windows)

You **do not need a patched WoW client** for the first version. When you
have already saved your *local test-realm* account in Windows Credential Manager
and calibrated the login form, perform one additional supervised calibration
on the *character selection* screen, with exactly the target character
selected but not yet in the world:

```powershell
.\.venv\Scripts\forge.exe --config forge.local.toml client character calibrate --character Test
```

Point at two static character-selection UI details and the visible **selected
character name** when requested. Choose a patch containing the whole short
name plus stable UI details, not moving animations. This records 3 small RGB
reference patches and the window dimensions inside the **marked separate test
client**. Keep resolution/UI scale unchanged.

On later sessions, **close the test client** before running:

```powershell
.\.venv\Scripts\forge.exe --config forge.local.toml agent prepare --start-client --login --enter-character Test
```

After the vault-based login succeeds, Forge waits for the exact calibrated
character selection screen in the **same newly launched executable process**
and only then presses Enter. It aborts without clicking or pressing Enter if
the expected process, pixels, name signature, or resolution differs. **This
new feature is not live-verified yet.** Selecting a character via pixels is
fragile on animated/customized screens; it can also match another screen if
the reference patches are not sufficiently distinctive. The preparation command immediately runs a correlated ForgeTestBridge v2
smoke report and independently checks the actual in-world player name.
It reports `character_verified` only after that proof, and otherwise aborts;
`agent run-plan` is still needed for each addon's behavior assertions.

The linked [awesome-wow-335-clients collection](https://github.com/haha2345/awesome-wow-335-clients)
includes client modifications, but the full unattended path does not
require untrusted binary patches. For example, Awesome WotLK mentions
command-line auto-login (exposing process arguments), while WoWee is an
independent, incomplete engine with different addon-compatibility
characteristics. We do **not** download, bundle, or patch any `Wow.exe`.

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
sources, deploys the addon and bridge, sends a correlated in-game smoke
suite, reads a version 2 SavedVariables snapshot, and evaluates the
independent JSON checks. The approval flag also authorizes server fixture
mutations when `peers > 0`. It doesn't automatically turn on a disabled
addon or restart an already-running WoW process.

Reports/screenshot evidence go into `examples\.forge-runs`.

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

Run `opencode` from the Forge checkout; its `AGENTS.md` gives it the
repository's addon/test contract. Example user instruction:

> Build a WotLK 3.3.5a party addon under projects/MyParty, register observed
> frames with ForgeTestBridge, write a measurable acceptance plan beside
> the addon folder, preview the plan and run only authorized tests. Don't
> weaken failing tests. Report coverage gaps, retain test evidence and fix
> code issues, not infrastructure issues.

OpenCode can **author and drive these CLI workflows**, but a universal,
fully unattended `forge agent build-and-test` command, native
`forge ai --backend opencode`, character selection, and model-planned
combat/quest/party scenarios are **not yet implemented**.

## Interpreting test outcomes

| Outcome | Meaning |
| --- | --- |
| `passed` | Requested in-game tests and independent checks passed for **that specific scenario** |
| `failed` | An assertion or independent expected condition failed |
| `infrastructure_error` | No reliable correlated evidence; no conclusion about addon correctness |
| `plan_only` | Dry-run preview; **nothing was tested or changed** |

The bridge report is in `WTF/Account/*/SavedVariables/ForgeTestBridge.lua`
inside the **isolated** client. Python correlates it with a random run ID
after `/reload`, and collects a JSON report and (when available) PNG
screenshot. Each snapshot can include player/target class, health, level,
party membership/count and registered frame visibility/dimensions.

**Fail closed:** a missing/mismatched snapshot, outdated `bridgeVersion`,
stale report, wrong character, or unexpected client window must not be
silently interpreted as an addon success. Treat screenshots as supporting
evidence, not a substitute for independent assertions.

## Troubleshooting

| Symptom | Check / action |
| --- | --- |
| `Old ForgeTestBridge loaded` / no v2 snapshot | Close test WoW, redeploy bridge, restart and re-enable it |
| `forge test` has no report | Ensure in-world, bridge enabled and client foregroundable; see [SavedVariables troubleshooting](local-realm.md) |
| Warden preflight error | Check the local-only Docker override and actual worldserver logs |
| Wrong Go version | Run `go version` **inside** AzerothCore's `e2e` folder with `GOTOOLCHAIN=auto` |
| Peer count mismatch | Update Forge; Go and Python readiness formats must agree |
| `party-lifecycle` fails | Capture the exact stage and errors; do not reset Docker or weaken checks |
| Auto-login fails | Keep the Windows session unlocked; recalibrate only the marked test client |

## Verification status

These are **user-observed local results**, not a guarantee on other machines:

| Scenario | Status | Evidence |
| --- | --- | --- |
| Real-client smoke `bridge_loaded` and addon assertion | **Verified** | Correlated in-game SavedVariables round trip |
| `ForgeExample` independent frame/player checks | **Verified** | User-provided v2 report, all checks passed; run `4d29d6d11e33` |
| One AzerothGhost peer appears and is targeted | **Verified** | User-provided peer test passed; run `60bb9bfee84b` |
| Three-peer bot party / peer departure lifecycle | **Verified live** | v2 target assertions passed at stages `61f0feae27df` and `e88eaee835cd`; bot-only group, GUI player `party.count: 0` |
| Four-peer party, GUI player membership and addon party frames | **Not verified live** | Separate membership/health/UI assertions still required |
| Calibrated login and selected character entry | **Experimental, not live-verified** | One-time visual calibration then PID-bound login/Enter and mandatory correlated bridge v2 identity check |
| Combat, quests, buffs, items and full autonomous QA | **Not implemented** | Future capability work |

Even verified smoke tests cover only their stated conditions. Preserve
screenshots/reports locally and do not commit any private realm credentials,
full client files, or login screens.
