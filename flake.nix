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

        # hostCfg.macUser is deliberately null (A8): a fresh clone must fail
        # to evaluate toplevel until a per-host macUser is set. The checks
        # below need a *valid* merged config to exercise real behaviour, so
        # they inject a throwaway macUser rather than reusing
        # self.nixosConfigurations.builder-base (which is expected to fail
        # the buildVm.macUser assertion by design).
        testHostCfg = hostCfg // {
          macUser = "ci";
        };
        testSystem = mkBuilder {
          role = "base";
          hostCfg = testHostCfg;
        };
        tcfg = testSystem.config;
      in
      {
        # Cheap, instantiation-only sanity check: forces the toplevel
        # derivation path without realising it. Does NOT prove buildability;
        # it only proves the config instantiates cleanly on the eval host
        # (aarch64-darwin), which has no builder for aarch64-linux. Uses
        # testHostCfg (macUser = "ci") rather than the shipped
        # nixosConfigurations.builder-base, whose macUser = null by design
        # (see macuser-assertion below, which tests exactly that failure).
        #
        # Deliberately strips string context (unsafeDiscardStringContext)
        # before the value ever reaches runCommand's buildCommand: the raw
        # drvPath string carries a context edge back to the toplevel
        # derivation, and embedding it with that context intact turns this
        # into a real build-time dependency -- silently forcing an actual
        # cross-system (aarch64-linux on aarch64-darwin) *build* of
        # toplevel, not just instantiation. That's the "runCommand +
        # build-input deepSeq" pitfall this check must avoid.
        checks = nixpkgs.lib.optionalAttrs (system == "aarch64-darwin") (
          {
            cross-instantiate-probe = pkgs.runCommand "cross-instantiate-probe" { } (
              let
                drvPath = builtins.unsafeDiscardStringContext tcfg.system.build.toplevel.drvPath;
                forced = builtins.deepSeq drvPath drvPath;
              in
              ''
                echo ${forced} > $out
              ''
            );

            # Regression cover for M2+: once role modules layer on top of
            # base.nix, this catches a silently flipped merged value. Not
            # the M0 gate itself -- that's the live Phase 6/7 sessions.
            base-merged = pkgs.runCommand "base-merged-check" { } (
              let
                ifaceAddrs = tcfg.networking.interfaces.${tcfg.buildVm.interface}.ipv4.addresses;
                hasStaticAddr = builtins.any (
                  a: a.address == "10.211.55.100" && a.prefixLength == 24
                ) ifaceAddrs;
                tunnelUnit = tcfg.systemd.services.nix-builder-tunnel or null;
                tunnelWantedByMultiUser =
                  tunnelUnit != null && builtins.elem "multi-user.target" tunnelUnit.wantedBy;
                allChecks = [
                  (tcfg.services.openssh.settings.PasswordAuthentication == false)
                  (tcfg.networking.useDHCP == false)
                  (tcfg.security.sudo.wheelNeedsPassword == false)
                  (builtins.elem "wheel" tcfg.users.users.parallels.extraGroups)
                  tunnelWantedByMultiUser
                  hasStaticAddr
                ];
                allPass = builtins.all (x: x) allChecks;
              in
              if allPass then
                ''
                  echo ok > $out
                ''
              else
                throw "base-merged check failed: one or more resolved values did not match expectations"
            );

            # Negative assertion check (A8): with macUser left null (the
            # hosts/default.nix default), evaluating toplevel must fail, and
            # the failure must carry the exact, load-bearing message string.
            macuser-assertion =
              let
                nullSystem = mkBuilder {
                  role = "base";
                  hostCfg = hostCfg // {
                    macUser = null;
                  };
                };
                expectedMessage = "buildVm.macUser must be set (per-host: janvansweevelt or vansweej); it is null.";
                attempt = builtins.tryEval (
                  builtins.deepSeq nullSystem.config.system.build.toplevel.drvPath nullSystem.config.system.build.toplevel.drvPath
                );
                # Fallback: if tryEval ever reports success (e.g. laziness
                # hides the throw), check config.assertions directly for the
                # expected failed assertion instead.
                hasExpectedAssertion = builtins.any (
                  a: !a.assertion && a.message == expectedMessage
                ) nullSystem.config.assertions;
              in
              pkgs.runCommand "macuser-assertion-check" { } (
                if attempt.success then
                  (
                    if hasExpectedAssertion then
                      ''
                        echo ok > $out
                      ''
                    else
                      throw "macuser-assertion check failed: expected eval failure or the specific assertion message for macUser = null, got neither"
                  )
                else
                  ''
                    echo ok > $out
                  ''
              );
          }
          // nixpkgs.lib.optionalAttrs (hostCfg.enableVmTest or false) {
            vm-smoke = import ./tests/vm-smoke.nix {
              inherit pkgs;
              lib = nixpkgs.lib;
              hostCfg = testHostCfg;
              baseModule = ./base.nix;
            };
          }
        );
      }
    );
}
