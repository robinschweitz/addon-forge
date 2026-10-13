# NixOS Addon Forge development VM

Addon Forge provides a complete local NixOS test appliance: Xfce/X11, Wine, the Forge CLI and a Docker-managed AzerothCore test realm on guest loopback. No AzerothCore checkout is required.

## Build and boot (Nix x86_64 Linux host)

    git clone https://github.com/robinschweitz/addon-forge.git
    cd addon-forge
    nix flake lock
    nix build .#nixosConfigurations.forge-vm.config.system.build.vm
    ./result/bin/run-forge-vm-vm

Commit the generated flake.lock to pin nixpkgs. The VM requests six virtual CPUs, 12 GiB RAM, and an 80 GiB disk. KVM acceleration and a graphical host are strongly recommended. Launching from the same directory keeps its generated qcow2 volume. Do not delete this volume if you want to keep your test realm database.

## First boot

The systemd unit automatically creates a Compose file and a randomly generated database password in /var/lib/addon-forge-realm (accessible only to root and members of the root-equivalent docker group). AzerothCore data and database import come from upstream OCI images. The first run downloads large images and initializes MySQL.

    systemctl status addon-forge-realm
    forge-realm status
    forge-realm logs ac-db-import
    forge-realm logs ac-worldserver

If provisioning failed:

    sudo systemctl restart addon-forge-realm
    journalctl -u addon-forge-realm -e

Once the worldserver is running, enter its console and create an account with credentials you choose:

    forge-realm console
    account create YOUR_USERNAME YOUR_PASSWORD YOUR_PASSWORD

Detach without stopping the server using Ctrl-P then Ctrl-Q. Database and client-data named volumes persist across container restarts; never run docker compose down -v unless you intend to delete the realm.

## Install your own client

The proprietary WoW 3.3.5a build 12340 client **is not distributed**. Import authorized client files from a VM shared folder or removable virtual drive to /home/forge/Games/WoW-3.3.5a. For client and realm in the SAME VM, set Data/<locale>/realmlist.wtf to: set realmlist 127.0.0.1. A VM without hardware-accelerated graphics may be unable to run WoW under Wine; verify this manually first.

In the VM:

    git clone https://github.com/robinschweitz/addon-forge.git
    cd addon-forge
    cp /etc/addon-forge/forge.toml ./forge.toml
    forge doctor
    forge deploy wow/ForgeTestBridge
    forge deploy examples/ForgeExample
    forge client start

Log into the test character and enable the bridge/addon, then test:

    forge test --suite smoke --require-test example_frame_visible

The game client and automated Wine GUI tests have not yet been boot-tested in this image. Initial account and character login is still manual.

## Install into an existing NixOS VM

Import addon-forge.nixosModules.default into your own NixOS flake, and set:

    services.addon-forge = {
      enable = true;
      user = "YOUR_EXISTING_USER";
      realm.enable = true;
    };

This adds the CLI and a systemd-managed realm without modifying your existing desktop or login. The Compose YAML is Nix-generated. The two game ports (3724, 8085) bind to guest 127.0.0.1; MySQL and admin ports are not forwarded.

## Reproducibility and security

Nix packages are reproducible only after flake.lock is committed. Upstream server images default to mutable :master tags, and MySQL defaults to :8.0. Pin services.addon-forge.realm.images.{database,authserver,worldserver,dbImport,clientData} by OCI digest (compatible set) to control binary drift. The realm database, game files and generated credentials remain persistent mutable data outside the Nix store. No test account password is baked into the flake.

The VM auto-logs in as forge and grants passwordless sudo to that local account. Do NOT expose this appliance to an untrusted network, enable SSH, or forward ports without securing the guest first. Members of the docker group have root-equivalent privileges.
