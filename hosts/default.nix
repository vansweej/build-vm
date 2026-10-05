{
  macUser = "janvansweevelt";
  staticIp = "10.211.55.100";
  prefixLength = 24;
  gateway = "10.211.55.1";
  nameservers = [ "8.8.8.8" ];
  interface = "enp0s5";
  tunnelTargetHost = "10.211.55.2";
  authorizedKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ1CCDrIAwTEKsXf5hEOzf5paPVdTpRGUjpGsSr2r0gI janvansweevelt@MACMWFT2V7XYJ"
  ];
  enableVmTest = false;

  # Per-host disk layout, read off this specific Parallels guest's real
  # `lsblk -f` / hardware-configuration.nix during Leg 2 (Phase 7). The
  # installer doesn't label partitions, so base.nix's prior generic
  # "/dev/disk/by-label/nixos" stub never matched any real disk and hung
  # early boot waiting for a device that doesn't exist. UUID-based,
  # per-host, here -- not hardcoded in base.nix -- because a re-rolled
  # guest will get fresh UUIDs and this is exactly the file meant to carry
  # per-host values. Update these on every guest re-roll.
  rootDevice = "/dev/disk/by-uuid/587ee538-56cc-43d2-b678-654b54519df0";
  rootFsType = "ext4";
  bootDevice = "/dev/disk/by-uuid/6295-1D39";
  bootFsType = "vfat";
}
