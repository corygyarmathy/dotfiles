# Wait for the LAN before calling the network online
#
# Holds `network-online.target` until each named interface has a usable IPv4
# address, so every service ordered after it starts on a working network.
#
# WHY THE STOCK TARGET IS NOT ENOUGH. On the servers, two things currently
# vouch for `network-online.target`, and neither waits for the address:
#
# - `NetworkManager-wait-online` runs `nm-online -s`, which waits for
#   NetworkManager's startup to finish. A port with no carrier counts as
#   finished after a few seconds.
# - dhcpcd forks into the background after its 30-second timeout whether or
#   not it got a lease, and systemd takes that as started.
#
# On 2026-11-26 homelab01's switch port took two and a half minutes to link.
# The target was reached 30 seconds in, and everything ordered after it
# started without a network. matterjs-server was the one that showed it:
# matter.js joins its mDNS multicast group only on the interfaces that are up
# when it starts and never joins later, so it could not see a single
# commissionable device until it was restarted by hand.
#
# WHY 169.254 IS EXCLUDED. When dhcpcd gives up on a lease it assigns an
# IPv4LL address, and on these hosts the kernel reports it as `scope global`,
# so filtering on scope alone would treat a link with no DHCP as online.
#
# WHAT A TIMEOUT DOES. The unit fails, and `network-online.target` is reached
# anyway: services only `Wants=` the target, so a NIC that never comes up
# leaves the host where it was before this module, plus one failed unit for
# SystemdUnitFailed to page on. It does not hang the boot.
#
# A module rather than a host setting for the same reason as
# ./wake-on-lan.nix: the interface name is a fact about the hardware, so the
# host names it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.wait-online;
in
{
  options.cg.wait-online = {
    enable = lib.mkEnableOption "holding network-online.target until the LAN interfaces have an address";

    interfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "eno1" ];
      description = ''
        Interfaces that must each have a routable IPv4 address (anything but
        169.254.0.0/16) before `network-online.target` is reached.
      '';
    };

    timeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = ''
        How long to wait before giving up. On giving up the unit fails and
        the target is reached anyway. The default is twice the slowest link-up
        seen so far (homelab01, 2026-11-26).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.interfaces != [ ];
        message = "cg.wait-online is enabled but cg.wait-online.interfaces is empty; name the interface in hosts/<host>/.";
      }
    ];

    systemd.services.wait-online = {
      description = "Wait for ${lib.concatStringsSep ", " cfg.interfaces} to have an address";
      wantedBy = [ "network-online.target" ];
      before = [ "network-online.target" ];
      path = [
        pkgs.iproute2
        pkgs.gawk
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # The script enforces its own deadline so it can say which interface
        # it was waiting for; this only catches the script itself hanging.
        TimeoutStartSec = cfg.timeoutSeconds + 30;
      };
      script = ''
        deadline=$((SECONDS + ${toString cfg.timeoutSeconds}))

        address() {
          ip -4 -o addr show dev "$1" scope global 2>/dev/null \
            | awk '$4 !~ /^169\.254\./ { print $4; exit }'
        }

        for iface in ${lib.escapeShellArgs cfg.interfaces}; do
          until addr="$(address "$iface")" && [ -n "$addr" ]; do
            if [ "$SECONDS" -ge "$deadline" ]; then
              echo "$iface has no routable IPv4 address after ${toString cfg.timeoutSeconds}s; giving up" >&2
              exit 1
            fi
            sleep 1
          done
          echo "$iface has $addr"
        done
      '';
    };
  };
}
