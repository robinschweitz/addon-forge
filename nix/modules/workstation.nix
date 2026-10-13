# NixOS workstation plus optional self-contained AzerothCore test realm.
# Private realm and database never enter the Nix store.
{ forgePackage }:
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.services.addon-forge;
  realm = cfg.realm;
  state = "/var/lib/addon-forge-realm";

  dbPassword = "\${FORGE_DB_PASSWORD}";
  loginDb = "ac-database;3306;root;${dbPassword};acore_auth";
  worldDb = "ac-database;3306;root;${dbPassword};acore_world";
  characterDb = "ac-database;3306;root;${dbPassword};acore_characters";
  sharedEnv = {
    AC_LOGIN_DATABASE_INFO = loginDb;
    AC_WORLD_DATABASE_INFO = worldDb;
    AC_CHARACTER_DATABASE_INFO = characterDb;
    AC_DATA_DIR = "/azerothcore/env/dist/data";
    AC_LOGS_DIR = "/azerothcore/env/dist/logs";
    AC_CLOSE_IDLE_CONNECTIONS = "0";
  };
  compose = {
    name = "addon-forge";
    services = {
      ac-database = {
        image = realm.images.database;
        restart = "unless-stopped";
        environment.MYSQL_ROOT_PASSWORD = dbPassword;
        volumes = [ "forge-db:/var/lib/mysql" ];
        healthcheck = {
          test = [ "CMD-SHELL" ''mysql --user=root --password="$$MYSQL_ROOT_PASSWORD" --execute "SHOW DATABASES;"'' ];
          interval = "5s";
          timeout = "10s";
          retries = 40;
        };
      };
      ac-client-data = {
        image = realm.images.clientData;
        volumes = [ "forge-client-data:/azerothcore/env/dist/data" ];
      };
      ac-db-import = {
        image = realm.images.dbImport;
        depends_on.ac-database.condition = "service_healthy";
        environment = sharedEnv // { AC_DISABLE_INTERACTIVE = "1"; };
      };
      ac-authserver = {
        image = realm.images.authserver;
        restart = "unless-stopped";
        depends_on.ac-db-import.condition = "service_completed_successfully";
        ports = [ "127.0.0.1:3724:3724" ];
        environment = {
          AC_LOGIN_DATABASE_INFO = loginDb;
          AC_LOGS_DIR = "/azerothcore/env/dist/logs";
          AC_TEMP_DIR = "/azerothcore/env/dist/temp";
        };
      };
      ac-worldserver = {
        image = realm.images.worldserver;
        restart = "unless-stopped";
        stdin_open = true;
        tty = true;
        depends_on = {
          ac-database.condition = "service_healthy";
          ac-client-data.condition = "service_completed_successfully";
          ac-db-import.condition = "service_completed_successfully";
        };
        ports = [ "127.0.0.1:8085:8085" ];
        volumes = [ "forge-client-data:/azerothcore/env/dist/data:ro" ];
        environment = sharedEnv;
      };
    };
    volumes = {
      forge-db = { };
      forge-client-data = { };
    };
  };
  # JSON is valid Compose YAML. No mutable or credential-bearing file is stored in /nix/store.
  composeFile = pkgs.writeText "addon-forge-compose.yaml" (builtins.toJSON compose);
  composeArgs = ''--project-name addon-forge --env-file ${state}/.env -f ${state}/compose.yaml'';
  realmTool = pkgs.writeShellApplication {
    name = "forge-realm";
    runtimeInputs = [ pkgs.docker pkgs.coreutils ];
    text = ''
      set -euo pipefail
      if [[ ! -r ${state}/.env || ! -f ${state}/compose.yaml ]]; then
        echo "Realm not provisioned. Run: sudo systemctl start addon-forge-realm" >&2
        exit 2
      fi
      case "''${1:-}" in
        status) exec docker compose ${composeArgs} ps ;;
        logs) shift; exec docker compose ${composeArgs} logs --tail=100 "$@" ;;
        up) exec docker compose ${composeArgs} up -d ;;
        down) exec docker compose ${composeArgs} down ;;
        console)
          echo "Detach without stopping the server: Ctrl-P, Ctrl-Q" >&2
          exec docker compose ${composeArgs} attach ac-worldserver
          ;;
        *) echo "Usage: forge-realm {status|logs [service]|up|down|console}" >&2; exit 2 ;;
      esac
    '';
  };
in {
  options.services.addon-forge = {
    enable = mkEnableOption "Addon Forge WotLK addon-development workstation";
    user = mkOption {
      type = types.str;
      default = "forge";
      description = "Existing non-root developer account to add to the docker group (root-equivalent).";
    };
    realm = {
      enable = mkEnableOption "locally managed AzerothCore test realm";
      images = {
        database = mkOption { type = types.str; default = "mysql:8.4"; description = "MySQL OCI image; pin by digest for stronger reproducibility."; };
        authserver = mkOption { type = types.str; default = "acore/ac-wotlk-authserver:master"; description = "Authserver image (supports image digest pinning)."; };
        worldserver = mkOption { type = types.str; default = "acore/ac-wotlk-worldserver:master"; description = "Worldserver image (supports image digest pinning)."; };
        dbImport = mkOption { type = types.str; default = "acore/ac-wotlk-db-import:master"; description = "DB bootstrap image."; };
        clientData = mkOption { type = types.str; default = "acore/ac-wotlk-client-data:master"; description = "Pre-extracted server data image; ensure licensing for your use."; };
      };
    };
  };
  config = mkIf cfg.enable {
    assertions = [
      { assertion = (!realm.enable) || config.virtualisation.docker.enable;
        message = "Addon Forge realm requires Docker."; }
    ];
    virtualisation.docker.enable = true;
    # Export the non-secret Compose template for CI validation. The actual
    # random password lives only in /var/lib/addon-forge-realm/.env.
    environment.etc."addon-forge/realm-compose.json" = mkIf realm.enable {
      source = composeFile;
    };
    users.users.${cfg.user}.extraGroups = [ "docker" ];
    environment.systemPackages = with pkgs; [
      forgePackage git lua5_1 docker docker-compose
      xdotool imagemagick wineWowPackages.stable
    ] ++ lib.optionals realm.enable [ realmTool ];

    # The realm is local to the VM: do not expose the game service to the LAN.
    # Additional access requires an explicit networking/authentication design.
    systemd.services.addon-forge-realm = mkIf realm.enable {
      description = "Addon Forge local AzerothCore test realm";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      requires = [ "docker.service" ];
      after = [ "docker.service" "network-online.target" ];
      path = [ pkgs.docker pkgs.coreutils pkgs.openssl ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "45min";
      };
      script = ''
        set -euo pipefail
        install -d -m 0750 -o root -g docker ${state}
        if [[ ! -f ${state}/.env ]]; then
          # Only root / docker group can read it; never part of the Nix store.
          printf 'FORGE_DB_PASSWORD=%s\n' "$(openssl rand -hex 32)" > ${state}/.env.tmp
          chown root:docker ${state}/.env.tmp
          chmod 0640 ${state}/.env.tmp
          mv ${state}/.env.tmp ${state}/.env
        fi
        install -m 0640 -o root -g docker ${composeFile} ${state}/compose.yaml
        docker compose ${composeArgs} up -d
      '';
      preStop = ''
        if [[ -r ${state}/.env ]]; then
          docker compose ${composeArgs} down
        fi
      '';
    };
  };
}
