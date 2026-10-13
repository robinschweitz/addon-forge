# Cloud realm bootstrap (preview)

The Hetzner CLI creates only an SSH-firewalled **Ubuntu bootstrap server**. It does not yet install NixOS, provision AzerothCore, or create a remote graphical client. Do not treat this as a turnkey cloud deployment.

1. In Hetzner Cloud Console, create a project, upload an SSH public key and generate a project API token.
2. Keep the token on your machine using the official `hcloud` CLI context or `HCLOUD_TOKEN`. Never put secrets in Git or chat.
3. Run:

```bash
cp cloud/hetzner.toml.example cloud/hetzner.toml
# Replace the SSH key and SSH source IP; verify server availability and live cost.
python3 scripts/cloud/hetzner.py plan
python3 scripts/cloud/hetzner.py check
python3 scripts/cloud/hetzner.py apply --approve-cost
```

**Apply creates billable resources.** The script first creates a firewall allowing incoming TCP/22 only from one specified public IP, then attaches that firewall when creating the server. The AzerothCore realm's own TCP 3724/8085 ports remain local-only. Delete unused resources in Hetzner Console to stop charges; also check separate volumes and backups.

## NixOS installation, not automatic yet

Once this disposable server is reachable via SSH, install NixOS with a separately audited disk layout and SSH authorized keys using [nixos-anywhere](https://github.com/nix-community/nixos-anywhere). This is destructive and may wipe the disk. This repository exports `nixosModules.cloudRealm` to be imported **alongside** `nixosModules.default` from your own host configuration. It enables the headless AzerothCore realm and disables Wine/X11.

Do not run `nixos-anywhere` until the exact boot device, filesystem, bootloader, SSH keys and recovery plan are verified on a disposable instance. Live cloud installation has not been tested.

GPU game testing requires a separate Linux worker; the headless cloud realm has neither a WoW client nor graphics acceleration.
