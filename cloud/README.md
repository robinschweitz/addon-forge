# Hetzner Cloud Addon Forge realm — NixOS installation (experimental)

This installs a **headless** x86_64 NixOS server with Docker + AzerothCore, not a GPU-backed WoW client. WoW requires a separate GPU-capable worker; the realm binds only to localhost. No public game ports are opened.

## Preparation

1. Create a fresh **disposable x86_64** Ubuntu 24.04 Hetzner Cloud server using `python scripts/cloud/hetzner.py apply --approve-cost` from the feature branch. Select an available type/location and check its **live price** first. A Hetzner server accrues charges until deleted (even while powered off).
2. Preserve the project-level `addon-forge-realm-ssh` firewall: it must allow inbound SSH (TCP 22) **only from your public IPv4 /32**. Never expose TCP 3306, 3724 or 8085 publicly.
3. On **Linux or WSL2 Ubuntu** (not native Windows PowerShell), install Nix with flakes, `hcloud`, OpenSSH, Python >=3.11 and git; import the same Hetzner CLI context in **WSL**, and make your SSH **private key locally available** to OpenSSH or ssh-agent. Never put your private key in Git, the cloud config or chat.
4. Check out the feature branch, verify the **committed Nix lock file** and evaluate the cloud NixOS configuration:

```bash
git switch feat/hetzner-cloud-provisioning
nix flake metadata --no-write-lock-file >/dev/null
nix eval --raw .#nixosConfigurations.forge-cloud.config.system.build.toplevel.drvPath
```

The `disko` dependency is pinned in `flake.lock`. Cloud installation remains experimental and should only be used on a disposable host until a live installation has been verified.

## Preflight (read-only)

Run from the repository root under WSL2/Linux, substituting a **public** key you own:

```bash
python3 scripts/cloud/install_nixos.py check --public-key ~/.ssh/id_ed25519.pub
```

This checks the project context, correct server name/ID, SSH access, and that the remote machine has **exactly one block disk named /dev/sda**. The installer intentionally refuses any other layout. Confirm the server ID printed by the check against `hcloud server list`. This operation does not modify the server.

## Destructive install — fresh server only

**Warning: `install` irreversibly repartitions and formats /dev/sda**, deleting Ubuntu and all data on it. Do this ONLY on a disposable server after verifying its ID and SSH key. You must supply both confirmation arguments:

```bash
python3 scripts/cloud/install_nixos.py install \
  --public-key ~/.ssh/id_ed25519.pub \
  --confirm-server-id YOUR_NEW_SERVER_ID \
  --confirm-wipe-disk /dev/sda
```

The installer runs `nix run github:nix-community/nixos-anywhere -- --flake .#forge-cloud --target-host root@SERVER_IP --extra-files ...`. It stages only your **public** SSH key in the new root account; no secrets are placed into the Nix store. NixOS enables key-only SSH and Docker; the Forge realm service starts at boot.

## Validate the deployed server

After the installer reboots the machine, SSH to its public IP from your trusted IP:

```bash
ssh root@SERVER_IP
systemctl status addon-forge-realm --no-pager
journalctl -u addon-forge-realm -n 100 --no-pager
forge-realm status
forge-realm logs ac-worldserver
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

A successful NixOS installation is **not** the same as proof that AzerothCore has initialized, the data images are valid, or a client can log in. Pulling several upstream OCI images and database imports can take many minutes. The Compose images currently use mutable tags and have **not been validated end to end** on a real running Hetzner server. First-boot failure diagnostics are in `journalctl` and `forge-realm logs`.

## Limits and ongoing operations

- Hetzner server is **not** the graphical WoW test worker. Real client/Wine/automated in-game testing still needs a separate machine and account.
- Game ports 3724/8085 are bound to 127.0.0.1, so a remote WoW client cannot directly connect. Use an intentionally configured private tunnel / worker rather than opening public firewall ports.
- Docker named volumes and realm state persist on the server disk; they are **destroyed** when you delete the server unless you explicitly back them up. `/var/lib/addon-forge-realm/.env` is generated on first start and must be kept private.
- For ordinary updates, deploy a new tested NixOS closure instead of reinstalling the disk. Use `nixos-rebuild` with a suitable host flake or SSH deploy process.
