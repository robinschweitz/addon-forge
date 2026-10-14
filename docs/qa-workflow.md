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

The new lifecycle attempts to form a **bot-to-bot** party, checks the
client's targeted peer, makes the last bot leave and checks again.
These stages are implemented and have Python unit tests, but have
**not been live-verified** as an end-to-end group scenario.

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
| 3–4 bot party / peer departure lifecycle | **Implemented, not yet verified live** | Python CI regression checks only |
| Calibrated login + full character selection | **Partial** | Login submission implemented; no autonomous character selection |
| Combat, quests, buffs, items and full autonomous QA | **Not implemented** | Future capability work |

Even verified smoke tests cover only their stated conditions. Preserve
screenshots/reports locally and do not commit any private realm credentials,
full client files, or login screens.
