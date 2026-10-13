# Purpose-built, disposable local developer VM. Do not expose to untrusted networks.
{ lib, pkgs, ... }: {
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
  environment.systemPackages = with pkgs; [ firefox xfce.thunar git ];
}
