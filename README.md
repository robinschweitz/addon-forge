# Addon Forge

**Experimental Linux-first WotLK 3.3.5a addon development and test toolkit.**

This repository contains a real, runnable Python CLI, a WoW 3.3.5a test companion addon, a safe SavedVariables report parser, static validators, an X11/Wine client controller, guarded AI generation/repair, tests and a Nix development environment.

**Status (v0.1.0):** Python tests can run on any Linux workstation. The Wine + WoW + AzerothCore integration path is implemented but **has not been validated on a running game client**. The graphical IDE, deterministic combat fixtures and fully hands-off login are future milestones. Never interpret static checks alone as proof an addon works in game.

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

The controller verifies the WoW executable path and foreground window, restricts commands to `/forge` and `/reload`, and reads the same ForgeTestBridge SavedVariables results as Linux/Wine. **Real-client Windows integration has not yet been validated**; Windows CI tests use a mocked Win32 UI.

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

- `nix develop`: Python, pytest, Lua 5.1, Wine, xdotool, ImageMagick, GitHub CLI, Docker CLI/Compose.
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

Log in manually, enable both addons in the add-on list, and reach the world. The bridge exports an account-wide `ForgeTestReport` SavedVariable after a reload. It only supports its own `/forge run SUITE RUN_ID` test command; it cannot arbitrarily read/write files or network.

```bash
forge client screenshot .forge-runs/first.png
forge test --suite smoke --require-test example_frame_visible
```

`forge test` sends `/forge run smoke <random-id>`, then `/reload`, waits for a **matching** SavedVariables report under `WTF/Account/*/SavedVariables/ForgeTestBridge.lua`, checks assertion results and Lua errors, and saves JSON/screenshot artifacts. A missing report is an **infrastructure error**, not an addon failure. Requires a live X11 session and the client already **in-world**. `forge client command` deliberately restricts automated chat input to `/forge` and `/reload`.

## AI usage

Point the CLI to an **OpenAI-compatible chat completions API**. Credentials live only in environment variables, not in `forge.toml`:

```bash
export FORGE_AI_BASE_URL='https://api.openai.com/v1'
export FORGE_AI_MODEL='YOUR_JSON_CAPABLE_MODEL'
export FORGE_AI_API_KEY='YOUR_API_KEY'

forge ai create SimpleTracker 'Make a minimal movable WotLK unit tracker'
forge ai repair projects/SimpleTracker --max-attempts 3
# After bridge is deployed, test character is in-world and addon is enabled:
forge ai repair projects/SimpleTracker --in-client --max-attempts 3
```

In-client repair requires a `forge.spec.json` contract listing `required_tests` with at least one addon-specific assertion (see the example). The AI cannot modify the contract.

The AI can change only `.toc`, `.lua`, `.xml` files within the addon directory. It has no shell interface. The source is restored on failed repair. In-client mode requires a *previously enabled* addon; newly generated addons may require a client restart and manual enable first. Model API support for `response_format: json_object` varies; configure a compatible provider.

**Security notes:** Use this with a private test realm where you are authorized to automate the client. Model output is untrusted; review generated Lua before entering a public/private multiplayer realm. The test bridge should not be included in release archives. Project-specific tests and broader security sandboxing remain planned work.

## Commands

```text
forge doctor
forge check PATH_TO_ADDON
forge deploy PATH_TO_ADDON
forge client start
forge client command '/reload'
forge client screenshot OUTPUT.png
forge realm up|down|status
forge test --suite smoke --require-test example_frame_visible
forge ai create NAME 'DESCRIPTION'
forge ai repair PATH_TO_ADDON [--in-client] [--max-attempts 3]
```

## Publish to GitHub

New GitHub repository creation is not available through the connected integration in this environment. From a Git-enabled project checkout on your computer, after `gh auth login`, run:

```bash
gh repo create addon-forge --private --source=. --remote=origin --push
```

For the downloadable `addon-forge.git.bundle`, first run `git clone addon-forge.git.bundle addon-forge` and enter the cloned directory; the history and `main` branch are already included. GitHub repository creation is a separate explicit user action.

## Roadmap

- [x] Python CLI, configuration loader, static TOC/API checks
- [x] Restricted client input, screenshots, Wine process start
- [x] In-game bridge, SavedVariables parser, report correlation
- [x] AI create/repair logic and rollback
- [x] Nix flake for development shell/package/NixOS module
- [x] Evaluate the NixOS module and boot a lightweight NixOS test VM in CI; commit `flake.lock`
- [ ] Verify real Wine + WoW 3.3.5a client round trip
- [ ] Test realm fixtures and controlled real combat event tests
- [ ] Client readiness detection and automated account/character login
- [ ] Desktop UI (Tauri + React)
- [ ] Per-project immutable acceptance tests, stronger agent sandboxing
- [ ] Reproducible realm image and DB seeding

## License

MIT. The WoW client and all AzerothCore game assets are **not included**.
