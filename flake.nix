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
          forgePackage
          python
          python.pkgs.pytest
          python.pkgs.setuptools
          python.pkgs.wheel
          lua5_1
          git
          gh
          docker-client
          docker-compose
          wineWowPackages.stable
          xdotool
          imagemagick
        ];
        shellHook = ''
          export PYTHONPATH="$PWD/src''${PYTHONPATH:+:$PYTHONPATH}"
          forge() { python -m addon_forge.cli "$@"; }
          echo "Addon Forge — run: forge --help"
        '';
      };
      nixosModules.default = import ./nix/modules/workstation.nix { inherit forgePackage; };
      # A complete disposable VM, including the loopback-only AzerothCore test realm.
      # nix build .#nixosConfigurations.forge-vm.config.system.build.vm
      nixosConfigurations.forge-vm = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ self.nixosModules.default ./nix/hosts/forge-vm.nix ];
      };
      # Validate the exact Compose configuration emitted by the NixOS module.
      # No Docker daemon, game files or OCI downloads are necessary.
      checks.${system}.realm-compose = pkgs.runCommand "forge-realm-compose-check" {
        nativeBuildInputs = [ pkgs.docker-compose pkgs.python313 ];
      } ''
        cat > credentials.env <<'EOF'
        FORGE_DB_PASSWORD=ci-placeholder-not-a-secret
        EOF
        docker compose --env-file credentials.env \
          -f ${self.nixosConfigurations.forge-vm.config.environment.etc."addon-forge/realm-compose.json".source} \
          config --format json > rendered.json
        python ${self}/scripts/ci/check_compose.py rendered.json
        touch "$out"
      '';
      # Boots a small NixOS machine with the actual Addon Forge module.
      # The realm unit is present, but starting heavy external OCI images is
      # deliberately excluded from this deterministic PR smoke test.
      checks.${system}.vm-boot = pkgs.testers.runNixOSTest {
        name = "forge-vm-boot";
        nodes.machine = { lib, ... }: {
          imports = [ self.nixosModules.default ];
          system.stateVersion = "26.05";
          users.users.forge.isNormalUser = true;
          services.addon-forge = {
            enable = true;
            user = "forge";
            realm.enable = true;
          };
          systemd.services.addon-forge-realm.wantedBy = lib.mkForce [ ];
        };
        testScript = ''
          machine.start()
          machine.wait_for_unit("multi-user.target")
          machine.succeed("command -v forge")
          machine.succeed("command -v forge-realm")
          machine.succeed("systemctl cat addon-forge-realm.service")
          machine.succeed("test -e /etc/addon-forge/realm-compose.json")
          machine.succeed("test ! -e /var/lib/addon-forge-realm/.env")
          machine.succeed("systemctl is-enabled docker.service")
        '';
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
