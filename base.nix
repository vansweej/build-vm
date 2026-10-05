{
  lib,
  pkgs,
  config,
  hostCfg,
  ...
}:

let
  cfg = config.buildVm;
in
{
  options.buildVm = {
    macUser = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = hostCfg.macUser;
      description = "Mac-side user the guest tunnels back to over autossh. Must be set per-host.";
    };
    staticIp = lib.mkOption {
      type = lib.types.str;
      default = hostCfg.staticIp;
      description = "Static IPv4 address for the guest on the Parallels Shared network.";
    };
    prefixLength = lib.mkOption {
      type = lib.types.int;
      default = hostCfg.prefixLength;
      description = "CIDR prefix length for staticIp.";
    };
    gateway = lib.mkOption {
      type = lib.types.str;
      default = hostCfg.gateway;
      description = "Default gateway for the guest's static networking.";
    };
    nameservers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = hostCfg.nameservers;
      description = "DNS nameservers for the guest.";
    };
    interface = lib.mkOption {
      type = lib.types.str;
      default = hostCfg.interface;
      description = "Guest NIC name on the Parallels Shared network (e.g. enp0s5).";
    };
    tunnelTargetHost = lib.mkOption {
      type = lib.types.str;
      default = hostCfg.tunnelTargetHost;
      description = "Host (Mac) that the guest's autossh reverse tunnel connects to.";
    };
    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = hostCfg.authorizedKeys;
      description = "Public keys authorized for the parallels and root users on the guest.";
    };
  };

  config = {
    # Unfree gate: scoped to this module only, and scoped to prl-tools only.
    # Must live inside the NixOS nixpkgs instance (not at the flake level),
    # or hardware.parallels.enable fails trying to build unfree prl-tools.
    nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (pkgs.lib.getName pkg) [ "prl-tools" ];

    assertions = [
      {
        assertion = cfg.macUser != null;
        message = "buildVm.macUser must be set (per-host: janvansweevelt or vansweej); it is null.";
      }
    ];

    # --- Minimal boot/fs/stateVersion floor (A8) ---------------------------
    # This is only enough for `toplevel` to be reachable at eval time.
    # Leg 2's NixOS installer generates its own hardware-configuration.nix,
    # which overrides these mkDefault values with the real disk layout.
    # Never place the Nix store on prl_fs (the Parallels shared filesystem) --
    # it does not support the features the store needs.
    boot.loader.systemd-boot.enable = lib.mkDefault true;
    boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

    fileSystems."/" = lib.mkDefault {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
    };

    system.stateVersion = "24.05";

    # --- Static networking (Pitfall #3) ------------------------------------
    # No guest-side networking.hosts entry and no ssh alias for the Mac here:
    # the guest reaches the Mac only via the outbound autossh reverse tunnel
    # (Phase 3), never via a guest-resolved hostname/IP alias baked into
    # /etc/hosts. Keep this deliberately dumb.
    networking.hostName = "builder-base";
    networking.useDHCP = false;
    networking.interfaces.${cfg.interface} = {
      useDHCP = false;
      ipv4.addresses = [
        {
          address = cfg.staticIp;
          prefixLength = cfg.prefixLength;
        }
      ];
    };
    networking.defaultGateway = cfg.gateway;
    networking.nameservers = cfg.nameservers;
  };
}
