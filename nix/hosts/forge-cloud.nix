# Realm-only NixOS module. Import into a full host config with disko, boot
# loader, root filesystem, SSH authorized keys and stateVersion.
{ ... }: {
  services.addon-forge = {
    enable = true;
    user = "forge";
    client.enable = false;
    realm.enable = true;
  };
  users.users.forge.isNormalUser = true;
  services.openssh.enable = true;
  networking.firewall.enable = true;
  services.openssh.settings.PasswordAuthentication = false;
  services.openssh.settings.KbdInteractiveAuthentication = false;
}
