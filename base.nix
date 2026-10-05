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
    rootDevice = lib.mkOption {
      type = lib.types.str;
      default = hostCfg.rootDevice;
      description = "Per-host root filesystem device (by-uuid, since the installer does not label partitions).";
    };
    rootFsType = lib.mkOption {
      type = lib.types.str;
      default = hostCfg.rootFsType;
      description = "Per-host root filesystem type.";
    };
    bootDevice = lib.mkOption {
      type = lib.types.str;
      default = hostCfg.bootDevice;
      description = "Per-host ESP (/boot) device (by-uuid).";
    };
    bootFsType = lib.mkOption {
      type = lib.types.str;
      default = hostCfg.bootFsType;
      description = "Per-host ESP (/boot) filesystem type.";
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
    # Values come from hostCfg (per-host, via buildVm.rootDevice/rootFsType/
    # bootDevice/bootFsType) rather than a hardcoded guess, because the
    # NixOS installer does not label partitions by default: an earlier
    # generic "/dev/disk/by-label/nixos" stub matched no real disk and hung
    # early boot (systemd/initrd waiting indefinitely for a device that
    # never appears -- discovered live in Phase 7). If this flake is ever
    # changed to import a real hardware-configuration.nix (e.g. via an
    # absolute-path module added at deploy time), that would override these
    # mkDefault values with the installer's own detection; for now, the
    # per-host hostCfg values are the source of truth.
    # Never place the Nix store on prl_fs (the Parallels shared filesystem) --
    # it does not support the features the store needs.
    boot.loader.systemd-boot.enable = lib.mkDefault true;
    # false, not true: a precaution, not a confirmed fix. Live `nixos-rebuild
    # switch` repeatedly froze this VM hard (0% CPU, network unreachable,
    # needed a hypervisor-level reset) during Phase 7, and EFI NVRAM writes
    # were one suspect. Disabling this did NOT, by itself, stop the freeze --
    # it kept happening on live `switch` afterwards too. The freeze was only
    # avoided by using `nixos-rebuild boot` + a clean `reboot` instead of a
    # live `switch` (see docs/ssh-foundation.md). Left disabled here because
    # it's a safe no-op for an ESP that boots via its ext fallback path
    # anyway, not because it was proven to matter.
    boot.loader.efi.canTouchEfiVariables = lib.mkDefault false;

    fileSystems."/" = lib.mkDefault {
      device = cfg.rootDevice;
      fsType = cfg.rootFsType;
    };

    fileSystems."/boot" = lib.mkDefault {
      device = cfg.bootDevice;
      fsType = cfg.bootFsType;
    };

    system.stateVersion = "24.05";

    # --- Static networking (Pitfall #3) ------------------------------------
    # No guest-side networking.hosts entry and no ssh alias for the Mac here:
    # the guest reaches the Mac only via the outbound autossh reverse tunnel
    # (below), never via a guest-resolved hostname/IP alias baked into
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

    # TEMPORARY Phase 7 live-session diagnostic only: static networking isn't
    # coming up on the current guest and, by design (A4), there is no
    # password-based way in -- SSH is key-only and console login has no
    # password either. Auto-login the local console (console only; does not
    # touch sshd's key-only policy above) purely to inspect why
    # networking.interfaces.${cfg.interface} isn't bringing the link up.
    # MUST be reverted before M0 is considered done; tracked in
    # docs/ssh-foundation.md.
    services.getty.autologinUser = lib.mkDefault "root";

    # --- sshd, users, passwordless sudo ------------------------------------
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "prohibit-password";
      };
    };

    users.users.parallels = {
      isNormalUser = true;
      home = "/home/parallels";
      extraGroups = [ "wheel" ]; # load-bearing: sudo fails without this regardless of the flag below
      openssh.authorizedKeys.keys = cfg.authorizedKeys;
    };

    users.users.root.openssh.authorizedKeys.keys = cfg.authorizedKeys;

    # A5: parallels is key-only with no password, so default NixOS sudo
    # (which requires a password) fails closed. This, plus parallels staying
    # in wheel above, is what makes passwordless sudo actually work.
    security.sudo.wheelNeedsPassword = false;

    # Parallels guest tools spike: pulls unfree prl-tools via the predicate
    # above. Historically x86-centric with no confirmed prior aarch64 usage.
    #
    # STATUS (Phase 7, live): still UNRESOLVED, not confirmed either way.
    # Enabled it once and the VM froze solid during `nixos-rebuild switch`
    # activation. But every live `switch` attempt froze the same way
    # afterwards too, including with this line removed -- the freeze turned
    # out to be tied to live `switch` activation generally (specifically
    # suspected: a live DHCP->static networking reconfiguration), not
    # specifically to prl-tools. Left commented out for M0 purely out of
    # caution (plan resolution path (b)); the actual aarch64 prl-tools
    # outcome is still an open question. See docs/ssh-foundation.md Open
    # Decisions -- do not treat this as a confirmed finding.
    # hardware.parallels.enable = true;

    # --- Guest -> Mac reverse tunnel (Pitfall #4) ---------------------------
    # autossh keeps an outbound reverse tunnel open so the Mac can reach the
    # guest's sshd on localhost:2222 (Mac->guest store hop uses this port).
    # This is the *other* SSH hop from the Mac->guest nix-builder identity:
    # here the guest authenticates outbound to the Mac as cfg.macUser, using
    # a key generated ON THE GUEST (-i below), whose public half must be
    # appended to cfg.macUser's ~/.ssh/authorized_keys on the Mac. If that
    # key is missing, autossh refuses and it looks exactly like a Parallels
    # networking failure.
    #
    # StrictHostKeyChecking=no + UserKnownHostsFile=/dev/null (A6) are
    # deliberate here: this is our own Mac, over a host-only link, with
    # unattended first-connect on every fresh guest. Without this pairing, a
    # regenerated Mac host key would trip "HOST KEY CHANGED" on the guest
    # side and silently kill the tunnel. Revisit at M3.
    #
    # Restart on failure: PTY-severance on restart is expected and handled
    # by Restart=always + RestartSec.
    systemd.services.nix-builder-tunnel = {
      description = "Reverse SSH tunnel to Mac for remote Nix builder access";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      # Must be at the service top level, NOT under serviceConfig.
      environment.AUTOSSH_GATETIME = "0";

      path = [ pkgs.autossh ];

      serviceConfig = {
        User = "parallels";
        Restart = "always";
        RestartSec = 10;
        ExecStart = "${pkgs.autossh}/bin/autossh -M 0 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /home/parallels/.ssh/id_guest -N -R 2222:localhost:22 ${cfg.macUser}@${cfg.tunnelTargetHost}";
      };
    };
  };
}
