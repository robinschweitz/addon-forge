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
