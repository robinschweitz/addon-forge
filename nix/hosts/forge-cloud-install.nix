# Dedicated Hetzner Cloud NixOS x86_64 server. Disk layout is declared
# separately; never import the VM host here.
{ lib, modulesPath, pkgs, ... }: {
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "26.05";
  networking.hostName = "addon-forge-realm";
  networking.useDHCP = lib.mkDefault true;
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];
  # IPv4 DHCP only; add assigned IPv6 with a separate audited configuration.
  boot.initrd.availableKernelModules = [ "ahci" "virtio_pci" "virtio_scsi" "sd_mod" "ext4" ];
  boot.loader.grub = {
    enable = true;
    efiSupport = false; # Hetzner x86 cloud's legacy BIOS boot path.
  };
  boot.kernelParams = [ "console=ttyS0" ];
  boot.initrd.systemd.enable = true;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  environment.systemPackages = with pkgs; [ vim htop curl ];
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };
  users.users.root.hashedPassword = "!";
  # Root's SSH authorized_keys is supplied by nixos-anywhere --extra-files.
  # Never put a private key in Git, cloud-init userdata, or the Nix store.
  services.addon-forge.client.enable = false;
  services.addon-forge.realm.enable = true;
  # Use SSH root for recovery and maintenance; Forge is a non-login service user.
  users.users.forge = {
    isNormalUser = true;
    initialHashedPassword = "!";
  };
}
