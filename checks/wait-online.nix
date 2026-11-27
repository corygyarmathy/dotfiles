# checks/wait-online.nix
#
# Behaviour test for modules/nixos/wait-online.nix: a service ordered after
# `network-online.target` starts only once the named interface has a routable
# address, and a NIC that never comes up degrades to a failed unit rather
# than a hung boot.
#
# The interface is a dummy link that does not exist at boot, so the test
# decides when the "switch port" comes up. It gets a 169.254 address first,
# which is what dhcpcd assigns when it gives up on a lease, and which the
# kernel reports as `scope global`: the wait must not accept it.
let
  probe =
    { pkgs, ... }:
    {
      # Stands in for matterjs-server: records what the network looked like
      # at the moment it was allowed to start.
      systemd.services.online-probe = {
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        path = [ pkgs.iproute2 ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ip -4 -o addr show dev lan0 > /run/online-probe 2>&1 || true
        '';
      };
    };
in
{
  name = "wait-online";

  nodes = {
    machine = {
      imports = [
        ../modules/nixos/wait-online.nix
        probe
      ];
      system.stateVersion = "24.11";
      cg.wait-online = {
        enable = true;
        interfaces = [ "lan0" ];
      };
    };

    # The same, but the interface never appears and the wait is short.
    dead = {
      imports = [
        ../modules/nixos/wait-online.nix
        probe
      ];
      system.stateVersion = "24.11";
      cg.wait-online = {
        enable = true;
        interfaces = [ "lan0" ];
        timeoutSeconds = 5;
      };
    };
  };

  testScript = ''
    import time

    def state(node, unit):
        return node.succeed(f"systemctl show -p ActiveState --value {unit}").strip()

    start_all()

    with subtest("the target waits while the interface is missing"):
        machine.wait_until_succeeds(
            "[ \"$(systemctl show -p ActiveState --value wait-online.service)\" = activating ]"
        )
        time.sleep(5)
        assert state(machine, "network-online.target") == "inactive"
        assert state(machine, "online-probe.service") == "inactive"

    with subtest("a 169.254 address does not count"):
        machine.succeed(
            "ip link add lan0 type dummy",
            "ip link set lan0 up",
            "ip addr add 169.254.10.10/16 dev lan0",
        )
        time.sleep(5)
        assert state(machine, "wait-online.service") == "activating"
        assert state(machine, "online-probe.service") == "inactive"

    with subtest("a routable address releases the target, and dependents see it"):
        machine.succeed("ip addr add 192.0.2.10/24 dev lan0")
        machine.wait_for_unit("online-probe.service")
        assert state(machine, "wait-online.service") == "active"
        seen = machine.succeed("cat /run/online-probe")
        assert "192.0.2.10/24" in seen, f"probe started before the address: {seen!r}"

    with subtest("an interface that never comes up fails the wait without blocking the boot"):
        dead.wait_for_unit("online-probe.service")
        dead.wait_for_unit("multi-user.target")
        assert state(dead, "wait-online.service") == "failed"
        assert state(dead, "network-online.target") == "active"
  '';
}
