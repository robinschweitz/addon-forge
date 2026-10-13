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
