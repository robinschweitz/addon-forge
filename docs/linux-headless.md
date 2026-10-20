# Linux: headless live runs (NixOS, rootless Docker, Wine)

**Verified live on 2026-10-20** (NixOS, KDE Plasma on Wayland, rootless Docker 27.5, Wine 10.0,
original 3.3.5a enUS client): local AzerothCore realm from the upstream prebuilt images, two
accounts with characters created by the AzerothGhost fixture, login, and
`forge agent run-plan` with steps passing all checks (RaidLedger calendar plan: event created
with 3 invites, statuses confirmed in the realm database).

The test client runs on a **private, invisible Xvfb display**. Nothing appears on your desktop,
and keys go only to the test client. All input is typed: there is no SDK on Linux.

## Why a private display

- Under a Wayland desktop, XWayland accepts synthetic key presses (XTEST) only for the window the
  compositor focused, and xdotool cannot focus it: the password never reached the login field.
- A rootful Xwayland or a headless Weston aborts on XTEST input (libei).
- Xvfb has no such limits. It needs GLX for WoW, and Xvfb offers GLX only when its Mesa DRI
  drivers match the Mesa it was built with. On NixOS the system drivers (`/run/opengl-driver`)
  did not (GLX missing or hanging); `xvfb = "nix"` takes `xorg.xorgserver` and `mesa` from the
  same nixpkgs. WoW then renders with llvmpipe, which is fast enough for UI tests.

## One-time setup

```bash
python -m venv .venv && .venv/bin/pip install -e ".[linux]"   # keyring for the credential vault
.venv/bin/forge local-realm setup --source-wow "$HOME/Games/World of Warcraft 3.3.5a" \
    --test-wow "$HOME/Games/WoW-Forge-Test" --realm-dir "$HOME/azerothcore-wotlk" \
    --locale enUS --pull-images --disable-warden-for-fixtures            # preview
# ... the same with --approve-local-setup
```

- `--pull-images` uses the upstream prebuilt `acore/ac-wotlk-*` images instead of a long C++ build.
- With rootless Docker (`virtualisation.docker.rootless` with `setSocketVariable`), `DOCKER_HOST`
  points at `/run/user/<uid>/docker.sock`. Forge accepts exactly that socket as local, and writes a
  `docker-compose.override.yml` that runs the services as container root (= your user on the host);
  the images' own user cannot write `env/dist` there.
- `--disable-warden-for-fixtures` adds `AC_WARDEN_ENABLED=0` to that override: the AzerothGhost
  fixtures cannot log in otherwise. Only for this disposable loopback realm.

Accounts with characters (random passwords, stored only in the desktop's Secret Service, e.g.
KWallet; plaintext keyrings are refused). The Go fixture needs a C compiler (`nix shell nixpkgs#gcc`):

```bash
forge --config forge.local.toml local-realm create-member --account-name FORGETEST --character Test --slot main
forge --config forge.local.toml local-realm create-member --account-name FORGEMEMBER --character Raidmember
```

`forge.local.toml`:

```toml
[client]
automation_backend = "xdotool"
display = ":79"
xvfb = "nix"        # or "Xvfb" from PATH, plus dri_path = ".../lib/dri" if needed
```

In the test copy's `WTF/Config.wtf`: `SET accountName "FORGETEST"`, `SET realmName "AzerothCore"`,
`SET readEULA "1"`, `SET readTOS "1"`, `SET movie "0"`, `SET checkAddonVersion "0"`,
`SET gxApi "opengl"`.

## Every run

```bash
forge --config forge.local.toml local-realm start          # if the realm is down
forge --config forge.local.toml client headless             # Xvfb :79 + Wine client
forge --config forge.local.toml client login enter          # vault password, enter the world
forge --config forge.local.toml agent run-plan PLAN.json --approve-fixtures
forge --config forge.local.toml client screenshot shot.png
```

Needs `wine`, `xdotool` and ImageMagick `import` on PATH.

## How steps run

- Each step's Lua (the same templates as the SDK backend) is typed as a `/run` line. A typed line
  runs inside a real key press, so `hardware_click` is a plain click here (CalendarAddEvent works).
- WoW's chat box takes 255 characters: longer steps are typed in pieces into `ForgeStepBuffer` and
  run with `loadstring`. Each step stores its result in `ForgeStepResults[n]`, and the plan gets one
  extra check per step: `ForgeStepResults.n == "ok"`.
- `/forge watch PATH` lines tell the bridge which globals the next `/forge run` reports
  (`global_equals` checks); the report comes back through `/reload` and SavedVariables.
- The chat box opens a moment after Return: typing waits 0.7 s, or the first characters are lost.

## Limits

- Single-client plans only: `member`, `peers` and `fixtures` are refused on this backend for now.
- A typed `/reload` loads changed Lua files; new files in a TOC need a client restart.
- An edit box that keeps the keyboard focus (e.g. an export box that selects its text) swallows
  typed lines; steps after such a click see no chat input until the focus moves.
