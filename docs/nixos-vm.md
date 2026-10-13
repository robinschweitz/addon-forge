# One-config NixOS test appliance

Addon Forge's flake has a complete `nixosConfigurations.forge-vm` output. It is a **local development appliance**: Xfce/X11, Wine, `forge`, Docker, and an AzerothCore realm on the VM's loopback interface. The VM boots with a local desktop account, and a systemd unit starts the realm in the background.

## Quick start (from a Nix-enabled Linux host)

```sh
git clone https://github.com/robinschweitz/addon-forge.git
cd addon-forge
nix flake lock   # if no flake.lock exists; commit it to pin nixpkgs
nix build .#nixosConfigurations.forge-vm.config.system.build.vm
./result/bin/run-forge-vm-vm
```

Requirements for the host: x86_64 Linux, Nix with flakes enabled, QEMU/KVM (recommended), a working graphical display, and ample free disk/memory. The default test VM is configured for 6 vCPUs, 12 GiB RAM and an 80 GiB virtual disk. Its storage is persistent between runs when launched from the same directory; don't delete the generated `.qcow2` file if you want to retain the realm database. Your host must have enough free space for images and game data. If you have an existing NixOS VM instead of using `build.vm`, import the flake's module as shown below.

**Security:** this is for a local disposable VM, not a public server. It has Xfce auto-login, passwordless sudo for the VM-only `forge` account, and its WoW realm ports are bound to `127.0.0.1` **inside the guest**. Do not add SSH port forwarding or bridged public networking until proper accounts and firewall rules are configured.

## First boot

A systemd service prepares a local Docker Compose project in `/var/lib/addon-forge-realm`, generates a random database password in its private `.env`, and starts AzerothCore's database, data bootstrap, authserver and worldserver. First start pulls several large upstream OCI images and imports the database; it may take a while. If the VM has no network or insufficient disk space, the unit can fail. Check its logs before assuming the realm is ready.

In a VM terminal:

```sh
systemctl status addon-forge-realm
forge-realm status
forge-realm logs ac-db-import
forge-realm logs ac-worldserver
```

If the service failed, try `sudo systemctl restart addon-forge-realm` and inspect `journalctl -u addon-forge-realm -e`. If it is still initializing, follow logs; `docker compose ps` shows service states.

Once the worldserver is running, create a dedicated *non-admin* game account through the worldserver console:

```sh
forge-realm console
# Inside the console, choose your own credentials:
account create YOUR_USER YOUR_PASSWORD YOUR_PASSWORD
# Detach without stopping the server: Ctrl-P then Ctrl-Q
```

`forge-realm down` stops containers but retains their named volumes; `forge-realm up` resumes. Avoid `docker compose down -v` unless you intentionally want to destroy the local realm database.

## Bring your own WoW 3.3.5a client

The client is **not included**. Obtain and copy your own authorized build 12340 files into the VM at `/home/forge/Games/WoW-3.3.5a` using a VM shared directory/removable virtual disk, and ensure they are owned by `forge`. The VM must support sufficient guest GPU acceleration for Wine/OpenGL; QEMU software rendering may not be adequate. You can keep the server in the VM and run the graphical client on a Linux host instead, but in that arrangement you must explicitly configure *guest-accessible* realm networking (localhost inside the host is not localhost inside the guest).

Configure the client locale's `Data/<locale>/realmlist.wtf` with `set realmlist 127.0.0.1` when the client is running **inside** this VM. Verify manually that Wine can start the client and that it can log in to the realm before automating GUI tests.

In the VM, clone this project, then:

```sh
git clone https://github.com/robinschweitz/addon-forge.git
cd addon-forge
cp /etc/addon-forge/forge.toml ./forge.toml
forge doctor
forge check examples/ForgeExample
forge deploy wow/ForgeTestBridge
forge deploy examples/ForgeExample
forge client start
```

Once logged in to the test character, run `forge test --suite smoke --require-test example_frame_visible`. Addons need to be enabled at the character-selection screen. The current client controller still relies on manual first login and a working X11 graphical session.

## Use the module in a separately installed NixOS VM

You can install NixOS in your favorite hypervisor and enable the same workstation + realm configuration without using the prebuilt VM output:

```nix
{
  inputs.addon-forge.url = "github:robinschweitz/addon-forge";
  outputs = { nixpkgs, addon-forge, ... }: {
    nixosConfigurations.my-vm = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        addon-forge.nixosModules.default
        {
          services.addon-forge = {
            enable = true;
            user = "YOUR_EXISTING_USER";
            realm.enable = true;
          };
        }
      ];
    };
  };
}
```

The module assumes the `user` already exists, installs the CLI/desktop prerequisites, and creates a systemd service for the test realm. Unlike the disposable VM output, it does not automatically change your graphical login, admin permissions or desktop configuration.

## Reproducibility boundaries

- The Nix flake pins Nix dependencies **only after `flake.lock` is generated and committed**.
- The default AzerothCore Docker images currently use the upstream `:master` tag, which **is mutable**. For reproducible realm binaries, override `services.addon-forge.realm.images.{database,authserver,worldserver,dbImport,clientData}` using `image@sha256:...` values that are mutually compatible, and commit your chosen digests. Version drift between an upstream DB schema and binaries may require restoring a compatible snapshot.
- Database state and client files live outside the Nix store. Back them up or reset them as test fixtures; NixOS rebuilds do not erase the world database.
- NixOS cannot redistribute proprietary game clients. AzerothCore's pre-extracted client-data OCI image is obtained separately from upstream, and you should verify that using it fits your licensing and development environment.
- Real in-game rendering and automation have **not been validated** in this VM configuration. A real boot + Wine smoke test is the next milestone.

The Docker group grants root-equivalent permissions; use only trusted developer accounts on the VM. The generated `.env` is readable by root and the Docker group but is not included in the Nix store or Git. Compose binds the realm's TCP ports only to the guest loopback address, and does not expose MySQL or admin interfaces.

## CI verification matrix

GitHub Actions workflow `NixOS appliance CI` runs on pull requests and `main`:

| Check | What it proves | What it does not prove |
|---|---|---|
| Flake evaluation | NixOS VM and CLI derivations evaluate | Their builds succeed |
| Compose validation | The **actual rendered module config** is valid Compose, localhost-only for auth/world, uses external credentials and persistent DB storage | Images are present or healthy |
| NixOS VM boot | A minimal NixOS VM with the same workstation module boots, has `forge`, `forge-realm`, Docker integration and a configured realm service | The full Xfce/Wine desktop boots; OCI images start |
| Full desktop VM build | All graphical VM derivations build (manual dispatch `build_full_vm=true`) | Guest GPU rendering works |
| Live AzerothCore integration | External OCI images initialize and both game ports accept localhost TCP connections | WoW gameplay or addon tests pass |

The heavy `AzerothCore live integration (opt in)` workflow runs **only** on a runner labeled `addon-forge-realm` (with `self-hosted`, `linux`, `x64`). Provision it with Nix, Docker Compose v2, sufficient disk space and networking; then start the workflow manually from Actions. The script generates a disposable local DB password, waits up to 30 minutes, checks TCP readiness and shuts down containers without deleting named volumes. Isolate this runner to avoid reusing its realm state between test runs. TCP readiness is not a full gameplay assertion.

The fast PR VM test intentionally disables auto-starting the image-download-heavy realm unit; it still checks the service definition and its non-secret Compose template. In-client addon tests need a licensed 3.3.5a client, Wine GPU validation and automated login, so **those are not currently covered by GitHub Actions**.

The workflow warns until a committed `flake.lock` exists. Generate it on a Nix-enabled machine (`nix flake lock && git add flake.lock`) to pin exact nixpkgs inputs; then future CI verifies the lockfile can be used without rewrites. OCI images are still unpinned until digests are selected.
