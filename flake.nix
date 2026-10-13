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
      nixosConfigurations.forge-vm = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ self.nixosModules.default ./nix/hosts/forge-vm.nix ];
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
