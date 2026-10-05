# build-vm

NixOS flake for a Parallels-hosted builder VM used as a remote Nix
builder from a macOS host.

## Shape

- `flake.nix` exposes `mkBuilder { role, hostCfg, system ? "aarch64-linux" }`,
  which builds a `nixosSystem` from `./base.nix` plus, for any role other
  than `"base"`, `./roles/${role}.nix` layered on top.
- `nixosConfigurations.builder-base` is the `role = "base"` instance.
- `hosts/default.nix` carries the per-host config (`hostCfg`): static IP,
  interface name, tunnel target, the Mac-side user to tunnel to
  (`macUser`), and authorized SSH keys. `macUser` starts `null` and must
  be set per host before `base.nix` will evaluate to a `toplevel`.

## Milestone M0

This repository is at M0: `base.nix` only — boot/fs/stateVersion floor,
static networking, sshd + passwordless sudo for the `parallels` user, and
an `autossh` reverse tunnel back to the Mac. No role modules yet.

M0 was built and verified in an **interactive session**: the artifact
(this flake, `base.nix`, the eval-time checks) was written solo, then two
live legs proved it against real Parallels VMs — a throwaway Ubuntu guest
for transport only, then a fresh NixOS guest for the full handshake. See
`docs/ssh-foundation.md` for the full runbook, the manual gate table, and
current status.

## Two SSH hops

There are two distinct SSH relationships in this setup — keep them separate:

1. **Mac → guest store hop.** The Mac uses `~/.ssh/nix-builder` /
   `/etc/nix/nix-builder-key` to open `ssh-ng://nix-builder` into the
   guest, to run it as a remote Nix builder.
2. **Guest → Mac autossh hop.** The guest authenticates outbound to the
   Mac's Remote Login as `macUser`, using a key generated **on the
   guest**, whose public half must be appended to `macUser`'s
   `~/.ssh/authorized_keys` on the Mac. This is what the reverse tunnel
   (`-R 2222:localhost:22`) rides on.

Conflating these two hops is the single most common failure mode here;
see `docs/ssh-foundation.md` for the diagnosis path.
