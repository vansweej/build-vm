{
  description = "build-vm: NixOS Parallels builder VM flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self, nixpkgs, flake-utils }:
    let
      hostCfg = import ./hosts/default.nix;

      # mkBuilder: constructs a nixosSystem for a given role/hostCfg.
      # role = "base" uses only base.nix; any other role layers
      # ./roles/${role}.nix on top of base.nix.
      mkBuilder =
        {
          role,
          hostCfg,
          system ? "aarch64-linux",
        }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit hostCfg; };
          modules = [ ./base.nix ] ++ (if role == "base" then [ ] else [ ./roles/${role}.nix ]);
        };
    in
    {
      nixosConfigurations.builder-base = mkBuilder {
        role = "base";
        inherit hostCfg;
      };
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        # Cheap, instantiation-only sanity check: forces the toplevel
        # derivation path without realising it. Does NOT prove buildability;
        # it only proves the config instantiates cleanly on the eval host
        # (aarch64-darwin), which has no builder for aarch64-linux.
        checks = nixpkgs.lib.optionalAttrs (system == "aarch64-darwin") {
          cross-instantiate-probe = pkgs.runCommand "cross-instantiate-probe" { } (
            let
              forced = builtins.deepSeq self.nixosConfigurations.builder-base.config.system.build.toplevel.drvPath
                self.nixosConfigurations.builder-base.config.system.build.toplevel.drvPath;
            in
            ''
              echo ${forced} > $out
            ''
          );
        };
      }
    );
}
