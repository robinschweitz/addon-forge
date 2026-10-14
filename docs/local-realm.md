## Reduced-manual-work controls (Windows, experimental)

The one-time setup remains: a **marked isolated test WoW copy**, your local
AzerothCore configuration, a character created on that private realm, and
optionally saved credentials plus visual login calibration. After that:

```powershell
cd F:\addon-forge
git pull --ff-only
.\.venv\Scripts\forge.exe --config forge.local.toml agent prepare --start-client
```

This verifies the isolated copy, deploys the current ForgeTestBridge while
WoW is closed and launches only that client. If you configured the Windows
Credential Manager account and login-screen calibration previously, use
`agent prepare --start-client --login` to submit account credentials. It
**does not** automatically choose a character; account/login can fail closed
if visual calibration is stale. If WoW is already running, preparation
reports that fact without attempting to redeploy code into a live process.
Go toolchain selection, Docker isolation checks and server fixture cleanup
already happen automatically in approved test commands.

To exercise a staged **bot-to-bot** party lifecycle:

```powershell
.\.venv\Scripts\forge.exe --config forge.local.toml agent party-lifecycle --character Test --peers 3
.\.venv\Scripts\forge.exe --config forge.local.toml agent party-lifecycle --character Test --peers 3 --approve-fixtures
```

The preview doesn't change server state; approved execution creates
three disposable protocol players, forms their own party, verifies a
targeted player in WoW, removes the last bot from that party, checks
the remaining peer in WoW again, then logs out the protocol players.
Run the real graphical test client in-world before executing.
AzerothGhost owns this *bot party*; **the GUI character is not yet in
the group**, so this does **not** prove that an addon reacts to PARTY_MEMBERS_CHANGED
or health changes. That requires a verified invite/accept handshake and
two-sided party assertions, not blind UI clicks. Reports and screenshots
are under `.forge-runs`. If a fixture fails, Forge still releases/kills
its test process without deleting Docker volumes or wiping realm data.

# One-command local AzerothCore setup (Windows-first; experimental)

This setup uses official AzerothCore Docker Compose, a **separate copy of WoW**,
and a separate `forge.local.toml`. Your existing Rising Gods client is never edited.
The plan command does not clone, copy, build or start anything. No Hetzner charges.

## Prerequisites

- Windows 10/11 with **Docker Desktop using Linux containers** and Git
  (or Linux with locally running Docker Engine), plus Python >= 3.11.
- Adequate free disk space and RAM: WoW will be copied and Docker may
  download/build large AzerothCore images. Verify capacity before approving.
- An authorized **WoW 3.3.5a build 12340** folder containing `Wow.exe`.
  Close WoW before copying. Do not use a launcher to enter Rising Gods
  when testing Forge. Any custom launcher/client modifications may be incompatible.
- Addon Forge main branch, installed locally:
  `.\.venv\Scripts\python.exe -m pip install -e ".[windows]"`.

## Preview changes

Use your **real** existing WoW folder and choose a **new, non-existing folder**
for the test client. The example has an existing folder `F:\WoW-RisingGods`
and a new folder `F:\WoW-Forge-Test`.

```powershell
cd F:\addon-forge
.\.venv\Scripts\forge.exe local-realm setup --source-wow "F:\WoW-RisingGods" --test-wow "F:\WoW-Forge-Test" --locale deDE
```

The default AzerothCore clone location is `F:\azerothcore-wotlk` (next to
your `F:\addon-forge` checkout). To choose another location, use
`--realm-dir "F:\some-other-folder"`.

## Already have both folders? Reuse them

If you've **already copied WoW** and **already cloned AzerothCore**, you do
not need to copy or clone them again. Pass the full existing directory names,
and add `--adopt-existing-test-wow` to explicitly register your separate copy.

For example, if your original Rising Gods client is in `F:\\WoW-RisingGods`,
the copied game is `F:\\WoW-Forge-Test`, and your existing AzerothCore clone
is `F:\\azerothcore-wotlk`:

```powershell
.\.venv\Scripts\forge.exe local-realm setup --source-wow "F:\WoW-RisingGods" --test-wow "F:\WoW-Forge-Test" --realm-dir "F:\azerothcore-wotlk" --locale deDE --adopt-existing-test-wow
```

The command above is a **read-only preview**. After verifying the paths, add
`--approve-local-setup` to perform the setup. This moves the copied
client's `WTF` settings to `.forge-original-WTF-backup` (without deleting
them), preserves your original Rising Gods client, reuses the existing official
AzerothCore Git checkout, and sets up the local test environment.

### Existing test client, without `--source-wow`

If you have an independent test WoW installation already, you can omit
`--source-wow` entirely. Replace these example paths with your existing test
WoW directory and existing AzerothCore checkout:

```powershell
.\.venv\Scripts\forge.exe local-realm setup --test-wow "F:\WoW-Forge-Test" --realm-dir "F:\azerothcore-wotlk" --locale deDE --adopt-existing-test-wow
```

This command is a read-only preview. After you verify the paths, append
`--approve-local-setup` to authorize setup. **Be certain that
`--test-wow` is your separate test installation, not Rising Gods:** Forge
cannot infer that from a source path when no source is given. An existing
unregistered folder is never changed without both
`--adopt-existing-test-wow` and `--approve-local-setup`.

If the test folder does not yet exist, `--source-wow` is still required to
create one.

## Run the local setup (changes local files and uses Docker)

```powershell
.\.venv\Scripts\forge.exe local-realm setup --source-wow "F:\WoW-RisingGods" --test-wow "F:\WoW-Forge-Test" --locale deDE --approve-local-setup
```

It performs the following:

1. Checks local Docker Desktop/Linux containers and Git.
2. Clones official AzerothCore (or verifies an existing official checkout).
3. Creates a private, randomly generated database password in the
   AzerothCore checkout's `.env`. All published service ports (MySQL 3306,
   auth 3724, world 8085, SOAP 7878) bind **only to 127.0.0.1**.
   Existing untrusted `.env` is not overwritten.
4. Uses `docker compose config` to verify the resolved ports and password
   before starting containers. Aborts on unexpected ports or a remote Docker
   context.
5. Makes an isolated test copy of WoW. It omits `WTF`, `Cache`,
   screenshots and logs. A marker prevents overwriting unrelated folders.
6. Backs up the test copy's `Data/deDE/realmlist.wtf`, then points it
   to `127.0.0.1`, not Rising Gods. Creates `forge.local.toml`.
7. Deploys ForgeTestBridge and ForgeExample into the test copy, then starts
   AzerothCore with `docker compose up -d --build`.

The upstream first build, DB imports and client-data initialization may take
some time. A successful `docker compose up` does not guarantee the world
server is ready; inspect logs if it exits.

## Resume after a Windows MySQL port 3306 bind error

If the Docker images built successfully but startup failed with a Windows
`127.0.0.1:3306` bind error, **do not build again or delete your volumes**.
Use an alternative **host-side** database port:

```powershell
cd F:\addon-forge
git pull --ff-only
.\.venv\Scripts\forge.exe local-realm start --realm-dir "E:/wow-azeroth-core/azerothcore-wotlk" --db-port 13306 --approve-port-change
.\.venv\Scripts\forge.exe local-realm status --realm-dir "E:/wow-azeroth-core/azerothcore-wotlk"
```

The restart command preserves the original randomized database password,
Docker database volumes, your WoW test client, and the *internal* MySQL
container port 3306. It changes only the Windows published MySQL port to
`127.0.0.1:13306`, rechecks Docker's resolved port bindings and runs
`docker compose up -d --no-build`. It does not recreate the images.
If 13306 is also blocked/reserved, pick another free high port.

## Monitor, create an account, and run a test

```powershell
.\.venv\Scripts\forge.exe local-realm status
.\.venv\Scripts\forge.exe local-realm logs
.\.venv\Scripts\forge.exe local-realm console
```

When the world-server console is ready, type the account-creation command
yourself, choosing a password **not used for Rising Gods**:

```text
account create FORGETEST YOUR_OWN_PASSWORD
```

Detach from the console without stopping it using **Ctrl+P, then Ctrl+Q**.
Then start the isolated WoW client:

```powershell
.\.venv\Scripts\forge.exe --config forge.local.toml client start
```

Enable ForgeTestBridge and ForgeExample, log into the new private realm
using your test account, enter the world, then:

```powershell
.\.venv\Scripts\forge.exe --config forge.local.toml client screenshot .forge-runs\local.png
.\.venv\Scripts\forge.exe --config forge.local.toml test --suite smoke --require-test example_frame_visible
```

To stop your **local** containers (persistent DB data is preserved):

```powershell
.\.venv\Scripts\forge.exe local-realm stop
```

## Automatic local account creation (experimental)

After the worldserver is running, you can create a local test account without
typing its password in shell history:

```powershell
cd F:\addon-forge
.\.venv\Scripts\forge.exe local-realm create-account --realm-dir "E:/wow-azeroth-core/azerothcore-wotlk" --account-name FORGETEST
```

Forge prompts for the password and submits the standard `account create`
command through Docker's local worldserver console. It does not write the
password to a project file or include it in a command-line argument. This
Docker console integration has not yet been validated live; if the command
times out or fails, **check whether the account was created before retrying**.

## Windows slash command reliability

The native Windows controller now types using the WoW window's keyboard
layout, rather than assuming Forge and the game use the same layout. It waits
briefly after Enter opens chat, then submits the slash command. Test in an
unlocked, foreground WoW desktop, with both addons enabled, and check that
the chat displays the Forge addon output rather than a SAY message.

If the first test returns `infrastructure_error`, try running
`/forge run smoke manual123` manually and then `/reload` in-game; check
`WTF/Account/*/SavedVariables/ForgeTestBridge.lua`. A manually successful
slash command but failing automated run indicates input/control issues.

## Keep the test client in a small window

**Close WoW completely first** so its shutdown does not overwrite the video
configuration. Then, in `F:\addon-forge`:

```powershell
.\.venv\Scripts\forge.exe --config forge.local.toml client windowed --resolution 1280x720
.\.venv\Scripts\forge.exe --config forge.local.toml client start
```

This only changes the **separate test client's** `WTF/Config.wtf`.
It sets `gxWindow=1`, `gxMaximize=0`, and `gxResolution=1280x720`,
preserving the original file as `Config.wtf.forge-backup`. Do not run
the configuration command while WoW is running. WoW may still adjust window
geometry based on its UI settings; if so, select Windowed in Video Options.

## Troubleshoot missing Forge SavedVariables report

A functioning `/reload` by itself does not prove the
`/forge run` handler is registered or that its SavedVariables were
written. With both addons enabled and the character in-world, **type**
`/forge run smoke manual123` manually. You should see the assertion count.
Then type `/reload`, and in PowerShell:

```powershell
Get-ChildItem "F:\Wow\wow_second\WTF\Account" -Recurse -Filter ForgeTestBridge.lua | Select-Object FullName,LastWriteTime
```

Forge now includes `report_files_found`, available run IDs and parse
errors in `infrastructure_error` responses. Those diagnostics distinguish
an unloaded addon from stale/missing report files or parser problems.

## AI realm fixture API (experimental)

Full autonomous orchestration of persistent accounts/characters, parties, combat,
quests, UI interactions and independent success criteria is a **roadmap goal**,
not yet delivered.

First building block: Forge exposes a fixed set of upstream
AzerothCore/AzerothGhost protocol tests. Preview (no changes):

```powershell
cd F:\addon-forge
.\.venv\Scripts\forge.exe agent capabilities
.\.venv\Scripts\forge.exe agent realm-fixture create-character --realm-dir "E:/wow-azeroth-core/azerothcore-wotlk"
```

On an explicitly disposable local realm, after reviewing the plan, append
`--approve-fixtures` to execute. Fixed fixture names are
`create-character`, `login-world`, and `teleport`. This invokes reviewed
upstream test cases, **not arbitrary AI shell/SQL/GM commands**. Requirements:
Go 1.26+, recent AzerothCore checkout with `e2e/go.mod`, running
loopback-only Docker realm, Forge-created .env, and an *explicit* test-only
worldserver `AC_WARDEN_ENABLED=0` environment override (required by
the upstream harness; Forge never changes anti-cheat settings automatically).
It may not be available in the user's current checkout.

The upstream harness creates disposable account/character protocol fixtures
and its own cleanup; they do **not** directly control a graphical WoW player.
Next phase: persistent fixture sessions synchronized with actual WoW GUI,
deterministic multiplayer/quests/combat, independently verified game-state
and UI oracles, screenshots and bounded AI repair loops. This separate
capability-based design prevents an AI from accidentally destroying saved
players or accessing unrelated realms.

### Go 1.25.5 and automatic Go 1.26 selection

If `go version` shows Go 1.25.5 on Windows, **do not uninstall it**.
Forge uses `GOTOOLCHAIN=auto` while running the module, which allows
Go to download the Go 1.26 toolchain required by the pinned harness.

You can check the effective module toolchain without changing your
system's Go installation:

```powershell
cd E:\wow-azeroth-core\azerothcore-wotlk\e2e
$env:GOTOOLCHAIN = "auto"
$env:GOWORK = "off"
go version
cd F:\addon-forge
```

The first module invocation may need internet access to download a Go toolchain.
Forge checks this automatically during approved fixture preflight. The
`peer-test` read-only preview does not require Go or access your server.
Your local realm also needs the separate AzerothGhost test-only Warden setting;
Forge does not silently alter the server's anti-cheat configuration.

## Synchronized real protocol peer + graphical UI test (experimental)

A first vertical end-to-end slice is now available: an official AzerothGhost
harness bot is logged into the *same running local worldserver*, teleports to
the real WoW client character, remains online while the WoW client targets
it, and ForgeTestBridge asserts its name and player status. The bot is
released automatically even if client assertions fail. This uses **no patched
Wow.exe**, only a development addon and native Windows input.

Close WoW, update Forge, and deploy the updated bridge once:

```powershell
cd F:\addon-forge
git pull --ff-only
.\.venv\Scripts\forge.exe --config forge.local.toml deploy wow\ForgeTestBridge
.\.venv\Scripts\forge.exe --config forge.local.toml client start
```

Log into your **already-created test character** and leave it *in world*.
Preview with the actual **character** name (not account name):

```powershell
.\.venv\Scripts\forge.exe --config forge.local.toml agent peer-test --character YOURCHAR
```

To execute, explicitly add `--approve-fixtures`.

**Current limitations:** Go 1.26+ required; local realm must meet
the earlier AzerothGhost Warden/env safeguards; generated
`agent_scenarios/go.mod` pins AzerothGhost v1.0.8.
The harness is not yet live-tested against your Docker realm.
AzerothGhost fixtures may create test accounts and DB state.
The actual graphical character must already be logged in and near the
foreground; character selection is not automated. This test checks just
one real peer targeted by the addon, **not party frames, combat, quests,
or the full feature acceptance criteria of arbitrary addons**.
For multiplayer/quest coverage we should extend the same synchronized
harness with stable, isolated fixture APIs and independent assertions.
The GUI client is not modified or injected into; a more expressive
ForgeTestBridge is safer and keeps the original WoW binary intact.

## Reusable agent QA scenarios: server fixtures + independently checked client state

The new `forge agent run-plan` command loads a strict JSON scenario schema:
`version=1`, `addon` (directory beside plan), `character` (your actual
graphical test character), `peers` (0-4 persistent AzerothGhost players)
and `checks`. Supported independent checks are `player_in_world`,
`target_player`, `frame_visible` (registered frame), and
`party_count_at_least`. All expected values must be fixed **before**
the agent runs; the model cannot declare its own results as passes.

Example (already in repository):
`examples/forge-example-scenario.json`, verifying the player is in-world
and the real `ForgeExampleFrame` is displayed. Change its `character`
field to your local test character name. Update and deploy the bridge and
example addon and restart WoW so the new Lua code is loaded.

```powershell
cd F:\addon-forge
git pull --ff-only
.\.venv\Scripts\forge.exe --config forge.local.toml deploy wow\ForgeTestBridge
.\.venv\Scripts\forge.exe --config forge.local.toml deploy examples\ForgeExample
.\.venv\Scripts\forge.exe --config forge.local.toml agent run-plan examples\forge-example-scenario.json
```

Without approval the command is a read-only preview. With WoW in-world,
approved execution:

```powershell
.\.venv\Scripts\forge.exe --config forge.local.toml agent run-plan examples\forge-example-scenario.json --approve-fixtures
```

When `peers > 0` the plan runner uses a synchronized live-server fixture
and the `peer` suite. The first player is targeted through `/targetexact`
and the bridge asserts that it really is a player; you can add an independent
`target_player` check. This **does not** yet form a party with your
graphical character, so `party_count_at_least` will only pass if that
state was established separately. It does not automatically generate custom
combat or quest conditions. No database volume deletions or `Wow.exe`
modifications are performed.

### Using your already installed OpenCode agent

Run OpenCode from `F:\addon-forge` and instruct it to treat
`docs/local-realm.md`, `src/addon_forge/scenario_plan.py`,
`wow/ForgeTestBridge/Core.lua`, and `examples/forge-example-scenario.json`
as the available tool contract. It may write a new addon in
`projects/NewAddon`, register observable frames using
`ForgeTestBridge:RegisterFrame("MyFrame", frame)`, and write a JSON plan
beside it. It should run a preview before an approved test, then inspect
the JSON report and screenshots. Approval only authorizes bounded local
test fixtures and addon deployment, **not** arbitrary Docker/SQL commands.
In-client smoke tests still require a running, logged-in graphical test
character and any new addon to be enabled.

A future agent tool adapter can expose these operations directly to OpenCode.
The CLI runner is usable already; unrestricted AI-generated scenario scripts,
permanent multi-bot sessions, fully unattended login/character selection,
combat and quest fixture orchestration and screen-vision interaction are
still separate engineering milestones.

## Preventing a reused MySQL volume/password mismatch

AzerothCore's MySQL image only uses `DOCKER_DB_ROOT_PASSWORD` to initialize a
**new** data directory. Docker persists databases in a named volume after
containers stop. If the original `.env` is missing while an existing volume
remains, generating a new password would break database authentication.

Forge now checks for a pre-existing Compose MySQL volume **before generating a
new password**, and refuses to proceed when an existing volume has no matching
configuration. During `setup` and `start`, Forge starts only MySQL first
and waits for its credential-checked health status. A root authentication
failure (1045) stops the process with a diagnostic **before launching**
the DB importer or worldserver.

If your existing database already uses the wrong password, this prevention
does not change that password: reconcile it through MySQL using the original
credentials or its official non-destructive recovery procedure. Keep your
`.env` backed up, private, and never post its password. Forge does not
delete volumes, replace database passwords, or silently reset MySQL.

## Boundaries and recovery

- Never use `docker compose down -v` unless you intentionally wish to erase
  local AzerothCore database volumes. The Forge `stop` command does not remove volumes.
- No Hetzner server is created. Your production/Rising Gods account and config are not changed.
- If setup is interrupted, rerun the same command. Forge refuses to overwrite
  an unmarked test client, unexpected Docker Compose bindings or a non-official checkout.
- If AzerothCore reports a different realm address, inspect and set its
  `acore_auth.realmlist.address` to `127.0.0.1` for local-only access.
- The first end-to-end installation has not been run on a real local Docker
  Desktop + WoW instance; CI currently verifies the Python logic offline.
