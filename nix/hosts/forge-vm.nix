# Purpose-built, disposable local developer VM. Do not expose to untrusted networks.
{ lib, pkgs, ... }:
let
  clientFetcher = pkgs.writeShellApplication {
    name = "forge-fetch-client";
    runtimeInputs = [ pkgs.python313 pkgs.aria2 ];
    text = ''
      exec ${pkgs.python313}/bin/python3 ${./../../scripts/client_fetch.py} "$@"
    '';
  };
in {
  system.stateVersion = "26.05";
  # These settings make the full NixOS configuration evaluable as a bootable
  # system. The QEMU VM variant supplies its own ephemeral root filesystem.
  # /dev/vda is the intended target when installing this as a standalone image;
  # disk-image production still needs a partitioning/install module.
  fileSystems."/" = { device = "/dev/vda1"; fsType = "ext4"; };
  boot.loader.grub.devices = [ "/dev/vda" ];
  networking.hostName = "forge-vm";
  networking.networkmanager.enable = true;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  users.users.forge = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialHashedPassword = "!";
  };
  services.addon-forge = {
    enable = true;
    user = "forge";
    realm.enable = true;
  };

  services.xserver.enable = true;
  services.xserver.desktopManager.xfce.enable = true;
  services.xserver.displayManager.lightdm.enable = true;
  services.displayManager.autoLogin.enable = true;
  services.displayManager.autoLogin.user = "forge";
  # Client files are NOT in /nix/store: the host setup passes an optional
  # read-only QEMU 9p share. Import only on explicit guest-side request.
  environment.systemPackages = with pkgs; [
    firefox xfce.thunar git
    clientFetcher
    (writeShellApplication {
    name = "forge-import-client";
    runtimeInputs = [ pkgs.util-linux pkgs.coreutils ];
    text = ''
      set -euo pipefail
      if [[ "$(id -u)" != "0" ]]; then
        echo "Use: sudo forge-import-client" >&2
        exit 2
      fi
      mkdir -p /run/forge-client-share
      if ! mount -t 9p -o trans=virtio,version=9p2000.L,ro forgeclient /run/forge-client-share; then
        echo "No client share found. Start with nix run ...#setup -- --client /path/to/WoW" >&2
        exit 2
      fi
      trap 'umount /run/forge-client-share' EXIT
      if [[ ! -f /run/forge-client-share/Wow.exe && ! -f /run/forge-client-share/WoW.exe ]]; then
        echo "Share has no Wow.exe; unable to import" >&2
        exit 2
      fi
      mkdir -p /home/forge/Games/WoW-3.3.5a
      cp -a /run/forge-client-share/. /home/forge/Games/WoW-3.3.5a/
      chown -R forge:users /home/forge/Games/WoW-3.3.5a
      echo "Client imported. Review configuration and run forge doctor."
    '';
  }) ];
  # Host opt-in is communicated by a separate read-only QEMU 9p share.
  # Download occurs as the unprivileged guest 'forge' account, not as root.
  systemd.services.forge-client-fetch = {
    description = "Addon Forge opt-in first-boot WoW client download";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = [ pkgs.util-linux pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "0"; # Large download; never a prerequisite for multi-user.target.
    };
    script = ''
      set -euo pipefail
      install -d -m 0700 /run/forge-setup-config
      if ! mount -t 9p -o trans=virtio,version=9p2000.L,ro forgeconfig /run/forge-setup-config; then
        echo "No setup-config share; automatic client download not requested."
        exit 0
      fi
      trap 'umount /run/forge-setup-config' EXIT
      if [[ ! -f /run/forge-setup-config/download-source ]]; then
        echo "No third-party client download selected."
        exit 0
      fi
      source="$(cat /run/forge-setup-config/download-source)"
      case "$source" in
        rising-gods)
          if [[ -f /home/forge/Games/WoW-3.3.5a/Wow.exe || -f /home/forge/Games/WoW-3.3.5a/WoW.exe ]]; then
            echo "WoW client already installed; skipping the download."
            exit 0
          fi
          echo "User opted in to Rising Gods BitTorrent. Launching fetch as guest user forge."
          runuser -u forge -- ${clientFetcher}/bin/forge-fetch-client --source rising-gods
          ;;
        *)
          echo "Unsupported guest download source: $source" >&2
          exit 1
          ;;
      esac
    '';
  };
  services.openssh.enable = false;
  networking.firewall.enable = true;

  environment.etc."addon-forge/forge.toml".text = ''
    [client]
    wow_dir = "/home/forge/Games/WoW-3.3.5a"
    wine_prefix = "/home/forge/.local/share/addon-forge/wine"
    window_name = "World of Warcraft"
    report_timeout = 35

    [realm]
    source_dir = "/var/lib/addon-forge-realm"
  '';

  virtualisation.vmVariant.virtualisation = {
    memorySize = 12288;
    cores = 6;
    diskSize = 81920;
    graphics = true;
  };
  security.sudo.wheelNeedsPassword = false;
}
