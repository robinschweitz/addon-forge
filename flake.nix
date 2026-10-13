{
  description = "Addon Forge: reproducible Linux toolchain for WoW 3.3.5a addon development";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      python = pkgs.python313;
      forgePackage = python.pkgs.buildPythonApplication {
        pname = "addon-forge";
        version = "0.1.0";
        pyproject = true;
        src = self;
        build-system = [ python.pkgs.setuptools python.pkgs.wheel ];
        doCheck = false; # Run tests explicitly using nix develop --command pytest.
      };
    in {
      packages.${system}.default = forgePackage;
      apps.${system}.default = {
        type = "app";
        program = "${forgePackage}/bin/forge";
      };
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          python
          python.pkgs.pytest
          python.pkgs.setuptools
          python.pkgs.wheel
          lua5_1
          git
          docker-client
          docker-compose
          wineWowPackages.stable
          xdotool
          imagemagick
        ];
        shellHook = ''
          export PYTHONPATH="$PWD/src''${PYTHONPATH:+:$PYTHONPATH}"
          echo "Addon Forge — run: python -m addon_forge.cli --help"
        '';
      };
      nixosModules.default = { config, lib, pkgs, ... }:
        let cfg = config.services.addon-forge;
        in {
          options.services.addon-forge = {
            enable = lib.mkEnableOption "Addon Forge development workstation dependencies";
            user = lib.mkOption {
              type = lib.types.str;
              description = "Existing non-root user that may operate the local Docker test realm";
            };
          };
          config = lib.mkIf cfg.enable {
            # Workstation prerequisites only; does not download proprietary game files.
            virtualisation.docker.enable = true;
            users.users.${cfg.user}.extraGroups = [ "docker" ];
            environment.systemPackages = with pkgs; [
              forgePackage
              git
              lua5_1
              docker-compose
              xdotool
              imagemagick
              wineWowPackages.stable
            ];
          };
        };
      checks.${system}.python-tests = pkgs.runCommand "forge-python-tests" {
        nativeBuildInputs = [ python python.pkgs.pytest ];
      } ''
        cd ${self}
        export PYTHONPATH=${self}/src
        pytest -q
        touch $out
      '';
    };
}
