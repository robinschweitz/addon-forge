# Addon Forge

**Experimental WotLK 3.3.5a (build 12340) addon creation and test suite.**

Addon Forge gives a human or an AI agent a short, verifiable loop for building WoW 3.3.5a addons:

1. **Create**: `forge new MyAddon` scaffolds a Lua 5.1 addon, an offline spec and an acceptance plan.
2. **Check (milliseconds)**: `forge check` compiles every file with a real embedded Lua 5.1 and reads the bytecode for APIs that do not exist on 3.3.5a (`C_Timer`, `IsInGroup`, `table.unpack`, `:SetColorTexture`, ...) with file:line hints for the 3.3.5a replacement.
3. **Spec (sub-second)**: `forge spec` runs the addon in a headless 3.3.5a emulation: real load order, SavedVariables timing, events, OnUpdate time, slash commands, clicks, chat, units, groups, loot and `/reload`.
4. **Accept (real client)**: `forge agent run-plan` gates on 2 and 3, deploys, optionally runs realm fixtures, runs the in-game ForgeTestBridge suite over the WoWControlSDK and judges an independent snapshot against the plan's checks.

Agents use the same loop as typed tools through `forge mcp` (configured in `opencode.json` and `.mcp.json`).

**Status (v0.1.0, experimental):** Steps 1-3 run on any OS and are covered by the test suite. The native Windows graphical client + local AzerothCore bridge workflow and a single AzerothGhost peer were **verified live** earlier with bridge v2. The bridge v3 SDK transport (JSON report in one SDK call), the richer plan checks and the `master_loot` fixture are implemented and unit-tested but **not yet verified live**. See [Autonomous QA workflow and verification status](docs/qa-workflow.md).

## Autonomous addon QA: start here (Windows local realm)

**[Step-by-step QA workflow, OpenCode integration, test evidence, troubleshooting and live verification status](docs/qa-workflow.md)** is the canonical guide. **[Agent playbook](docs/agent-playbook.md)** collects the verified 3.3.5a and SDK lessons. The setup details remain in [local realm setup](docs/local-realm.md) and [native Windows guide](docs/windows-testing.md). Agents follow [AGENTS.md](AGENTS.md).

## Local AzerothCore realm — automated setup (experimental)

For Windows/Linux development without paying for a cloud server, see
[the local realm setup guide](docs/local-realm.md). The new
`forge local-realm setup` command can clone official AzerothCore, configure
Docker services to bind only to localhost, create a separate WoW test
copy that preserves your original server settings, deploy Forge addons and
start the realm. It previews changes unless you explicitly supply
`--approve-local-setup`. A real WoW/Docker integration run is still needed.

## Headless Hetzner Cloud realm (experimental)

Cloud deployment lives in [cloud/README.md](cloud/README.md). The opt-in
`hcloud` bootstrap creates a billable SSH-restricted x86 server; an independent,
explicitly destructive `nixos-anywhere` step installs a pinned NixOS system
with Docker, Forge CLI, generated database credentials and AzerothCore Compose.

The installation requires **Linux or WSL2** with Nix, hcloud, and SSH.
The cloud realm does **not** run a WoW client, offer GPU/X11 automation or
expose public game ports. Review CI and disk prerequisites before installing.

## Native Windows graphical WoW testing (experimental)

Windows 10/11 can use a **native WoW 3.3.5a client without Wine/WSL** for graphical smoke tests. See [Windows setup and limitations](docs/windows-testing.md). Install from Windows PowerShell with `py -3.11 -m pip install -e ".[windows]"`, configure `[client] wow_dir` in `forge.toml`, then use the existing `forge deploy`, `forge client start`, `forge client screenshot`, and `forge test` commands.

On Windows, suites run through the WoWControlSDK (`automation_backend = "wowcontrol"`): the bridge returns its report as JSON in the same call, with no `/reload` or SavedVariables round trip. The only typed input left is a validated `/targetexact NAME`, used by peer fixtures because targeting is a protected action. Login also goes through the SDK; the former pixel-calibrated keyboard login was removed. Windows CI uses a mocked Win32 UI and SDK. See the [verification matrix](docs/qa-workflow.md#verification-status).

## Complete Windows/Linux ↔ Hetzner workflow (experimental)

See [end-to-end setup](docs/end-to-end.md) for a secure **SSH-only** connection
between local WoW (Windows native or Linux/Wine) and a cloud NixOS AzerothCore
realm. The commands `forge realmlist --locale enUS` and
`forge tunnel YOUR_HETZNER_IP` configure backed-up local client settings and
forward login/world ports over SSH without opening public game ports. Remote
database realmlist settings must also point to loopback; see the guide.

Live Hetzner NixOS deployment and a full graphical WoW login have **not yet
been validated**; automated unit/NixOS CI checks do not replace an in-game run.

## NixOS all-in-one test VM (experimental)

A full local test appliance (Xfce/X11, Wine, Forge CLI, systemd-managed AzerothCore) is now described in [docs/nixos-vm.md](docs/nixos-vm.md). On a Nix-capable Linux host:

```bash
git clone https://github.com/robinschweitz/addon-forge.git
cd addon-forge
nix flake lock
nix build .#nixosConfigurations.forge-vm.config.system.build.vm
./result/bin/run-forge-vm-vm
```

The realm is provisioned on VM boot with generated database credentials. You must still provide your own authorized 3.3.5a game client, create a test account, and verify Wine graphics. This VM and its Nix evaluation are not yet tested on a live NixOS/KVM host. OCI images currently use mutable upstream tags.

## Quick start on NixOS / Linux with Nix

```bash
git clone <YOUR_GITHUB_REPO_URL> addon-forge
cd addon-forge
nix develop --extra-experimental-features 'nix-command flakes'
python -m pytest -q
cp forge.toml.example forge.toml
# Edit forge.toml to your installed *legitimate* 3.3.5a client and local AzerothCore checkout.
python -m addon_forge.cli doctor
python -m addon_forge.cli check examples/ForgeExample
```

The single main Nix configuration file is **`flake.nix`**. It defines:

- `nix develop`: Python, pytest, Wine, xdotool, ImageMagick, GitHub CLI, Docker CLI/Compose.
- `nix build`: packaged `forge` CLI.
- `nix run -- --help`: run the CLI.
- `nix flake check`: Python tests.
- `nixosModules.default`: opt-in NixOS workstation prerequisites for Docker/Wine/test control.

**Reproducibility note:** The committed **`flake.lock`** pins an exact nixpkgs revision, verified by CI. Update it intentionally using `nix flake update` and commit the result. The proprietary WoW client, game data, local realm DB, credentials, GPU setup, and upstream OCI container image tags are not yet reproducible from the flake alone.

To add the NixOS module to **your existing system flake** (do not replace your hardware configuration):

```nix
{
  inputs.addon-forge.url = "path:/home/YOUR_USER/Dev/addon-forge";
  # Within your nixosConfigurations.<hostname>.modules array:
  # addon-forge.nixosModules.default
  # { services.addon-forge = { enable = true; user = "YOUR_USER"; }; }
}
```

The Docker group has root-equivalent privileges; enable only for a trusted local developer account. The module does not force X11 as your main desktop session: use a dedicated X11 login/session for `xdotool` test control.

## Set up local realm

Use the official [AzerothCore Docker installation instructions](https://www.azerothcore.org/wiki/install-with-docker) with a **separate local test account**. Clone AzerothCore outside this project; enter its path in `[realm] source_dir`. Then:

```bash
forge realm up
forge realm status
```

Create test credentials and a character using the server console. Point the **authorized, locally installed** original WoW 3.3.5a client (build 12340) at the test realm. Do not distribute the client files in this repository. First verify manually that it starts under Wine and the test character enters the world.

## Deploy the bridge and an example addon

```bash
forge check wow/ForgeTestBridge
forge check examples/ForgeExample
forge deploy wow/ForgeTestBridge
forge deploy examples/ForgeExample
forge client start
```

Log in, enable both addons in the add-on list, and reach the world. The bridge only supports its own `/forge run SUITE RUN_ID` command and the SDK `ForgeTestBridge:RunJSON` call; it cannot read/write files or the network.

```bash
forge client screenshot .forge-runs/first.png
forge test --suite smoke --require-test example_frame_visible
```

`forge test` runs the suite with a random run id and checks the **matching** report's assertions and captured Lua errors, saving JSON/screenshot artifacts. On Windows the report comes back through the SDK; on Wine/Linux it is read from `WTF/Account/*/SavedVariables/ForgeTestBridge.lua` after `/reload`. A missing report is an **infrastructure error**, not an addon failure.

## Building addons with an agent

`forge ai` (a separate OpenAI-compatible backend) was removed in favour of the agent loop above. Point your agent at the MCP server; `opencode.json` and `.mcp.json` already register it:

```bash
forge --config forge.local.toml mcp            # check/spec/new/api tools; real-client runs refused
forge --config forge.local.toml mcp --allow-fixtures   # human opt-in: forge_run_plan may use the realm
```

Acceptance plans drive the real client with data-only `steps` (`slash`, `roll`, `wait`, `click`, `hardware_click`, `paste`, `screenshot`, ...; see [docs/qa-workflow.md](docs/qa-workflow.md)). `click` calls the frame's `Click()` from SDK Lua, which is no hardware event; for client functions that refuse that (`ADDON_ACTION_BLOCKED`, such as `CalendarAddEvent`), `hardware_click` clicks the same registered frame through a temporary key binding pressed with real input. The frame must have that global name.

Offline specs live in `projects/MyAddon/tests/*.spec.lua` and are never deployed:

```lua
before_load(function() forge.setSaved("MyAddonDB", { logins = 2 }) end)

test("/myaddon toggles the window", function()
    forge.slash("/myaddon")
    expect("MyAddonFrame").toBeHidden()
end)
```

The harness API: `forge.fire(event, ...)`, `forge.advance(seconds)`, `forge.slash(text[, {hardware = true}])`, `forge.click(frame)`, `forge.hardwareClick(frame)`, `forge.clickText(text[, button, {hardware = true}])`, `forge.type(editbox, text)`, `forge.press(editbox, "ENTER")`, `forge.unit(token, fields)`, `forge.party{...}`, `forge.raid{...}`, `forge.item(id, fields)`, `forge.openLoot{...}`, `forge.roll(name, value)`, `forge.combat(true)`, `forge.stub(name, value)`, `forge.saved(name)`, `forge.reload()`, `forge.chat()`, `forge.sent()`, `forge.addonMessages()`, `forge.blocked()`, `forge.protectedCalls()`, `forge.chatEvent(event, text, sender[, opts])`, `forge.bag(bag, slots, links)`, `forge.guild{...}`, `forge.invites()`, `forge.calendarPlayers{...}`, `forge.calendarEvents()`. Expectations: `toBe`, `toEqual`, `toContain`, `toMatch`, `toBeNil`, `toBeTruthy`, `toBeFalsy`, `toBeGreaterThan`, `toBeShown`, `toBeHidden`.

Addon and spec code run sandboxed (no `os`/`io`/Python access, instruction budget, memory cap). The emulation is not the client: anything it does not model is reported (unknown globals, unmodelled widget methods and templates) so the real-client plan stays the final gate. Run `forge api dump` once with the test client in world to record the real `_G` and widget method lists in `wow/api/` (git-ignored); checks and specs then flag anything that does not exist on 3.3.5a.

**Security notes:** Use this with a private test realm where you are authorized to automate the client. Model output is untrusted; review generated Lua before entering a public/private multiplayer realm. The test bridge should not be included in release archives.

## Commands

```text
forge doctor
forge new NAME [--notes TEXT] [--character NAME]
forge check PATH_TO_ADDON
forge spec PATH_TO_ADDON [--json]
forge api lookup NAME|Widget:Method ...
forge api dump
forge mcp [--allow-fixtures]
forge deploy PATH_TO_ADDON
forge client start | screenshot OUTPUT.png | login save --account NAME
forge test --suite smoke --require-test example_frame_visible
forge agent run-plan PLAN.json [--approve-fixtures]
forge agent session PLAN.json [--approve-fixtures]
forge realm up|down|status
```

## Publish to GitHub

New GitHub repository creation is not available through the connected integration in this environment. From a Git-enabled project checkout on your computer, after `gh auth login`, run:

```bash
gh repo create addon-forge --private --source=. --remote=origin --push
```

For the downloadable `addon-forge.git.bundle`, first run `git clone addon-forge.git.bundle addon-forge` and enter the cloned directory; the history and `main` branch are already included. GitHub repository creation is a separate explicit user action.

## Roadmap

- [x] Python CLI, configuration loader, static TOC/API checks
- [x] Embedded Lua 5.1 syntax + bytecode global analysis; 3.3.5a API dump and lookup
- [x] Headless 3.3.5a emulation with offline specs, gating real-client runs
- [x] In-game bridge, SDK JSON transport (v3), report correlation
- [x] Data-only acceptance plans with UI/text/SavedVariables/chat/event/error checks and named fixtures
- [x] MCP tool server and `forge new` scaffold
- [x] Nix flake for development shell/package/NixOS module
- [ ] Verify bridge v3 SDK transport and `master_loot` fixture live
- [ ] Combat and quest fixtures
- [ ] Reproducible realm image and DB seeding

## License

MIT. The WoW client and all AzerothCore game assets are **not included**.
