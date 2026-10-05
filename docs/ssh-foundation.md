# SSH foundation runbook (`build-vm` M0)

> **Status at end of this document: see the "SESSION BOUNDARY — resume
> here" marker and state block in the Manual Gate table below.** This
> runbook is written/updated across this session as Phases 6 and 7
> actually run against real Parallels VMs.

## The model: two SSH consumers, two hops

There are two completely separate SSH relationships in this setup. They
must be kept distinct — conflating them is the single most common failure
mode when something looks like a "Parallels networking problem" but isn't.

1. **Mac → guest store hop** (`ssh-ng://nix-builder`). The Mac uses its
   own `~/.ssh/nix-builder` / `/etc/nix/nix-builder-key` identity to open
   an SSH connection *into* the guest, over the loopback-tunneled port
   `2222`, to run the guest as a remote Nix builder
   (`/etc/nix/machines`). This is the connection `sudo nix store info
   --store ssh-ng://nix-builder` exercises.
2. **Guest → Mac autossh hop**. The guest authenticates *outbound* to the
   Mac's Remote Login (sshd) as `cfg.macUser`, presenting a key generated
   **on the guest** (`/home/parallels/.ssh/id_guest`). The public half of
   that key must be appended to `macUser`'s `~/.ssh/authorized_keys` **on
   the Mac**. This is what keeps the `-R 2222:localhost:22` reverse
   tunnel open in the first place.

The guest→Mac key is easy to forget, and an unset key makes autossh
refuse the connection in a way that is indistinguishable, from the
outside, from a genuine Parallels bridged/shared-network failure
(Pitfall #4 below). Set it up explicitly on every fresh guest, in both
Leg 1 and Leg 2.

## Why a reverse tunnel at all (Pitfalls #3 / #4)

- **Pitfall #3:** Parallels drops Mac→guest traffic in some bridged
  configurations in a way that is easy to misdiagnose as a guest-side
  firewall or sshd problem. `base.nix` therefore never bakes a
  `networking.hosts` alias or any other guest-side assumption about being
  able to resolve or reach the Mac inbound; the guest only ever *initiates*
  outbound connections.
- **Pitfall #4:** because of #3, the Mac cannot reliably connect inbound
  to the guest without a pre-established channel. The fix is an outbound
  `autossh` reverse tunnel, started by the guest, that punches a hole back
  to the Mac (`-R 2222:localhost:22`): once that tunnel is up, `ssh -p
  2222 ... localhost` *on the Mac* reaches the guest's sshd via the
  tunnel, without the Mac ever needing to dial the guest directly.

## Two-leg genesis (A2)

Every guest is born fresh (A1): new host key, new guest→Mac key, no
history. `base.nix` is proven against real Parallels VMs in two legs:

- **Leg 1 — throwaway Ubuntu guest.** Proves transport only: Parallels
  networking + the reverse tunnel + the Mac-side root ssh path. No Nix,
  no `base.nix`. See Phase 6 below.
- **Leg 2 — fresh NixOS guest.** Proves the actual `base.nix` artifact:
  sshd, passwordless sudo, the autossh unit, and the Mac→guest store
  handshake. See Phase 7 below.

This doc records what those two legs actually did, so a future guest
re-roll can replay the same steps without re-deriving them.

## Mac-side wiring (per fresh guest)

Each time a guest is reborn, its SSH host key changes, so the Mac's
knowledge of "how to reach this guest" has to be re-seeded:

1. **Re-seed `known_hosts` for the Mac→guest store hop**, in this exact
   order (reversed order silently appends a second, stale entry instead
   of replacing the one that's there):
   ```sh
   sudo ssh-keygen -R "[localhost]:2222"
   sudo ssh-keyscan -p 2222 localhost >> /var/root/.ssh/known_hosts
   ```
   This must run as root (`/var/root/.ssh/known_hosts`) because the
   Mac→guest store hop runs as root (`/etc/nix/machines`).
2. **Re-point `/etc/nix/machines`** at `ssh-ng://nix-builder` if it isn't
   already (it's re-pointed, not created — see Prerequisites).
3. **Append the guest's newly generated guest→Mac public key** to
   `macUser`'s `~/.ssh/authorized_keys` on the Mac (see "Two hops" above).

## Leg 1's `ExecStart`, byte-for-byte

This is the exact `autossh` invocation from `base.nix`'s
`nix-builder-tunnel` unit (Phase 3 Step 3), reproduced here so Leg 1 can
run the identical command imperatively on a guest with no Nix installed
yet:

```
autossh -M 0 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /home/parallels/.ssh/id_guest -N -R 2222:localhost:22 ${cfg.macUser}@${cfg.tunnelTargetHost}
```

With `cfg.macUser` and `cfg.tunnelTargetHost` substituted for the real
values (`tunnelTargetHost` is `10.211.55.2` — the Mac's own address on
the Parallels Shared network, confirmed live during Leg 1; *not*
`10.211.55.1`, which is the Parallels Shared-network gateway/router, a
distinct host).

Deliberate flags, and why:

- `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null` (A6): this
  is our own Mac, over a host-only/shared link, with unattended
  first-connect on every fresh guest. Without this pairing, a Mac host key
  regenerated between sessions would trip "HOST KEY CHANGED" on the guest
  side and silently kill the tunnel with no guest-side visibility.
  Revisit at M3.
- `-i /home/parallels/.ssh/id_guest`: presents the **guest→Mac** identity
  (hop 2 above), never the Mac→guest `nix-builder` identity. Its public
  half must already be in `macUser`'s `authorized_keys` on the Mac or the
  tunnel refuses.
- `environment.AUTOSSH_GATETIME = "0"` lives at the systemd service's top
  level in `base.nix`, not under `serviceConfig` — putting it under
  `serviceConfig` silently has no effect; `autossh` keeps treating fast
  restarts as flapping and giving up.

## DHCP caveat re `.100`

`hosts/default.nix` statically assigns the guest `10.211.55.100/24`
(`staticIp`). This address is inside the range Parallels' Shared-network
DHCP pool hands out by default. If a *different* guest on the same
Parallels network is DHCP-assigned `.100` before this guest's static
config takes effect, there will be an address conflict. In practice this
hasn't bitten us because this is the only long-lived guest on this
Mac's Parallels Shared network, but if that changes, either narrow the
DHCP pool in Parallels' network preferences or move `staticIp` outside it.

## Guest-pull, never Mac-push (F2)

The guest always fetches the flake itself —
`nixos-rebuild switch --flake github:vansweej/build-vm#builder-base` (or
an explicit `git clone` on the guest) — reaching GitHub over its own
outbound internet connection. **Nothing is ever `scp`'d from the Mac to
the guest.** This is not circular with Pitfall #4: that pitfall blocks
Mac→guest *push* traffic on the bridge, but the guest's own outbound
internet access (to GitHub, not to the Mac) is unaffected. Before Leg 2,
the working branch must be pushed to `github:vansweej/build-vm` so the
guest has something to pull.

## Leg 2 note: `hardware-configuration.nix` overrides the `mkDefault` stub

`base.nix`'s `fileSystems."/"` and boot-loader device settings are all
`lib.mkDefault` specifically so that the NixOS installer's generated
`hardware-configuration.nix` (produced during Leg 2's install) can
override them with the guest's real disk layout without a module
collision. If these were set without `mkDefault`, the installer's own
module would conflict with `base.nix`'s stub values.

## Remote Login GUI toggle (irreducible)

Enabling "Remote Login" under **System Settings → General → Sharing** on
the Mac is a manual, physical step with no CLI equivalent exposed to this
session. It must be toggled on before Leg 1's transport probe and must
stay on for Leg 2.

---

## Manual Gate table

Each row below maps to the corresponding roadmap gate line. "Check" means
regression cover from `nix flake check`; "session" means it was proven
live, in this interactive session, against a real Parallels VM.

| # | Gate line | Verified by | Status |
|---|-----------|-------------|--------|
| 1 | Flake evaluates on aarch64-darwin | check (`cross-instantiate-probe`) | ✅ check-verified |
| 2 | Merged config resolves intended values (sshd, sudo, wheel, tunnel unit, static IP) | check (`base-merged`) | ✅ check-verified |
| 3 | `macUser = null` gates `toplevel` with the exact message | check (`macuser-assertion`) | ✅ check-verified |
| 4 | Leg 1: Parallels transport (Mac→guest via reverse tunnel) | session | ✅ session-verified (exit 0) |
| 5 | Leg 2: Mac→guest Nix builder handshake (`nix store info --store ssh-ng://nix-builder`) | session | pending Phase 7 |
| 6 | `sudo -n true` on the guest (passwordless sudo + wheel, F3) | session | pending Phase 7 |
| 7 | Cold-boot connect (fresh guest boots, tunnel comes up unattended) | session | pending Phase 7 |
| 8 | Guest reboot reconnect (tunnel survives/re-establishes after `reboot`) | session | pending Phase 7 |
| 9 | `max-jobs=0` diagnostic (~10 min), then reverted | session | pending Phase 7 |
| 10 | Mac-reboot reconnect | session (deferred) | pending, past session boundary |
| 11 | Guest re-roll alias stability | session (deferred) | pending, past session boundary |
| 12 | Multi-hour idle+load soak (PTY-severance observation) | session (deferred) | pending, past session boundary |

### In-session lines (rows 4–9)

These run live, with Jan at the keyboard, inside this session:

- Leg 6 (row 4): fresh Ubuntu guest, transport-only pass criterion
  `sudo ssh -p 2222 -i /etc/nix/nix-builder-key parallels@localhost true`
  exits 0.
- Leg 7 (row 5–9): fresh NixOS guest, `base.nix` applied via guest-pull,
  then: cold-boot connect, guest reboot reconnect, the live
  `nix store info --store ssh-ng://nix-builder` handshake, `sudo -n true`
  on the guest, and the `max-jobs=0` ~10-minute diagnostic followed by a
  revert back to `max-jobs = auto` (A7 — `0` is never committed).

### — SESSION BOUNDARY — resume here —

Rows 10–12 require a Mac reboot, which would kill this very session (and
the SSH link it runs over). They are deferred to a follow-up session.

**State to resume from** (fill in as Phases 6/7 actually run):

- Leg 1 (Ubuntu) result: **PASSED.** Fresh Ubuntu 26.04 guest
  (`ubuntu-26-04`), DHCP address `10.211.55.19` on `eth0` (altname
  `enp0s5`, confirming the NixOS interface assumption holds). Guest
  generated `~/.ssh/id_guest` (ed25519); public half appended to
  `janvansweevelt`'s `~/.ssh/authorized_keys` on the Mac. Ran the
  byte-for-byte `ExecStart` autossh command manually in the foreground.
  Mac's `/etc/nix/nix-builder.pub` appended to the guest's
  `~/.ssh/authorized_keys` for `parallels` (this hop — Mac→guest store —
  was not pre-seeded on a throwaway guest and had to be added manually;
  Leg 2 will need the same). Final probe:
  `sudo ssh -p 2222 -i /etc/nix/nix-builder-key parallels@localhost true`
  → **exit 0**. Guest discarded after.

  **Two issues hit and fixed, both now folded into this runbook /
  `hosts/default.nix`:**
  1. `hosts/default.nix`'s `tunnelTargetHost` was wrong: `10.211.55.1` is
     the Parallels Shared-network **gateway/router**, not the Mac. The
     Mac's actual address on that network is `10.211.55.2` (confirmed via
     `ifconfig` on the Mac — bridge interface `10.211.55.2/24`). Fixed in
     `hosts/default.nix`; `gateway` correctly stays `10.211.55.1`.
  2. The throwaway Ubuntu guest had no `openssh-server` installed at all
     (`ssh.service` unit didn't exist), so both the local loopback test
     and the tunnel failed with "connection refused" / "closed by remote
     host" — nothing was listening on port 22 on the guest. Installed via
     `apt-get install -y openssh-server` + `systemctl enable --now ssh`.
     Not applicable to Leg 2 (NixOS ships/enables sshd via `base.nix`
     itself), but worth remembering if a throwaway transport-only guest
     is ever re-used for Leg 1 again.
- Leg 2 (NixOS) result: _pending_
- `prl-tools` spike outcome: _pending_ (see Open Decisions)
- In-session gate lines 5–9: _pending_
- Current guest IP / host key state: _pending_
- Anything re-seeded on the Mac (`known_hosts`, `authorized_keys`): _pending_

### Deferred lines (rows 10–12)

Run these in a follow-up session, after a Mac reboot:

- **Mac-reboot reconnect**: reboot the Mac, confirm the guest's autossh
  unit re-establishes the tunnel without manual intervention once the Mac
  comes back up and Remote Login is available again.
- **Guest re-roll alias stability**: destroy and recreate the NixOS guest
  from scratch, confirm the re-seed ritual (host key, guest→Mac key,
  `/etc/nix/machines`) is sufficient to restore the handshake with no
  additional changes to `base.nix`.
- **Multi-hour idle+load soak**: leave the tunnel up for several hours,
  both idle and under remote-build load, watching specifically for
  PTY-severance on `autossh` restart and confirming `Restart=always` /
  `RestartSec=10` actually recovers it.

**M0 is declared met only once every row in the Manual Gate table has
passed — in-session and deferred.** A green `nix flake check` at this
point in the repo's history means only that the artifact is well-formed
and self-consistent; it is regression cover, not the milestone.

---

## Open Decisions

- **PTY severance & tmux/mosh.** `autossh -M 0 -N` opens no PTY and no
  remote command, so this shouldn't apply, but `Restart=always` combined
  with how Parallels suspends/resumes network state across sleep needs
  observing under the multi-hour soak (row 12) before this is considered
  closed.
- **`prl-tools` on aarch64.** `hardware.parallels.enable = true` pulls
  unfree `prl-tools`, which has historically been x86-centric with no
  confirmed prior aarch64 usage. Outcome recorded live during Phase 7
  Step 2: _pending_.
- **Tailscale absent.** No mesh VPN is in play for M0; the reverse tunnel
  is the entire connectivity story. Revisit if/when guests need to reach
  anything beyond the Mac.
