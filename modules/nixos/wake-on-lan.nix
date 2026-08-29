# Wake-on-LAN
#
# Arms the NIC to come up on a magic packet, so a machine that is powered off -
# or that lost power and did not come back - can be started without standing in
# front of it. The BIOS has to allow it too; this only sets the NIC's side.
#
# WHY THIS IS A MODULE RATHER THAN PART OF profiles/server.nix. "Servers in this
# fleet answer to a magic packet" is a decision, and decisions belong in a
# profile - but arming the NIC means naming it, and an interface name is a fact
# about a particular machine's hardware. A profile has no options, so the two
# halves are split: the profile enables this module, and the host says which
# interface it has. Both servers happen to say `eno1`; neither of them assumes
# the other does.
#
# WHY ethtool RATHER THAN `networking.interfaces.<name>.wakeOnLan`. The stock
# option is the obvious thing to reach for and does the same job by writing a
# systemd `.link` file. It was tried and reverted: on homelab02 nothing else
# declares `networking.interfaces.eno1`, so declaring it there to reach the
# `wakeOnLan` attribute also pulled in a `network-addresses-eno1.service`, a
# udev rule to start it, and two new per-interface sysctls - including
# `net.ipv6.conf.eno1.use_tempaddr`, which changes how the host picks a source
# address. That is a real change to a running server smuggled in by a
# refactor. A `.link` file also only applies if it matches before the interface
# is renamed, which is not something this repository can check from here,
# whereas the unit below is what these two machines already run.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.wake-on-lan;
in
{
  options.cg.wake-on-lan = {
    enable = lib.mkEnableOption "Wake-on-LAN on this machine's wired interfaces";

    interfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "eno1" ];
      description = ''
        Interfaces to arm, by their runtime names. Set this where the hardware
        is described, not where the decision to wake is made.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Enabling this without naming an interface would produce a unit that
    # succeeds while arming nothing, and the failure would only show up the
    # next time someone needed the machine to come up.
    assertions = [
      {
        assertion = cfg.interfaces != [ ];
        message = "cg.wake-on-lan is enabled but cg.wake-on-lan.interfaces is empty; name the interface in hosts/<host>/.";
      }
    ];

    systemd.services.enable-wol = {
      description = "Enable Wake-on-LAN";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = map (iface: "${pkgs.ethtool}/bin/ethtool -s ${iface} wol g") cfg.interfaces;
      };
    };
  };
}
