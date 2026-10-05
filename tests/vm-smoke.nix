{
  pkgs,
  lib,
  hostCfg,
  baseModule,
}:

# Gated VM smoke test (buildVm.enableVmTest, default false): boots a real
# NixOS VM from base.nix and checks sshd actually comes up. This is the one
# check in this repo that realises the config, not just instantiates it --
# kept opt-in because it is slow and needs a working aarch64-linux builder.
pkgs.testers.runNixOSTest {
  name = "vm-smoke";

  nodes.machine =
    { ... }:
    {
      imports = [ baseModule ];
      _module.args.hostCfg = hostCfg;
    };

  testScript = ''
    machine.wait_for_unit("sshd.service")
    machine.succeed("systemctl is-active sshd.service")
    machine.succeed("systemctl is-enabled nix-builder-tunnel.service")
  '';
}
