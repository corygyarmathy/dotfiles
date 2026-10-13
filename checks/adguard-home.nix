# checks/adguard-home.nix
#
# Behaviour test for where AdGuard Home's web interface listens.
#
# The module asks for 127.0.0.1, since Caddy fronts the UI (cg.publish proxies
# to localhost). Until nixpkgs 7fd4004 the upstream module silently replaced
# that address with host:port, so both homelabs served the UI on 0.0.0.0:3080,
# open in the firewall and bypassing Caddy - and the build gate could not see
# it, because the configuration still said 127.0.0.1. So this asserts on the
# running process's sockets rather than on the configuration: whichever way
# nixpkgs spells the bind, what matters is what AdGuard actually listens on.
#
# DNS is deliberately left alone: it binds whatever the host lists, and the
# VM has no network to resolve against anyway.
{
  name = "adguard-home";

  nodes.machine =
    { ... }:
    {
      imports = [
        ../modules/services/adguard-home.nix
        (import ./stub-secrets.nix {
          secrets."adguard/admin-password" = "not-a-real-password";
        })
      ];

      networking.hostName = "adguard";
      system.stateVersion = "24.11";

      cg.service.adguard-home.enable = true;
    };

  testScript =
    { nodes, ... }:
    let
      port = toString nodes.machine.cg.service.adguard-home.webPort;
    in
    ''
      machine.wait_for_unit("adguardhome.service")
      machine.wait_for_open_port(${port}, "127.0.0.1")

      with subtest("the web interface listens on loopback only"):
          listeners = machine.succeed("ss -ltnH 'sport = :${port}' | awk '{print $4}'").split()
          assert listeners == ["127.0.0.1:${port}"], f"web interface listens on {listeners}"
          machine.succeed("curl -sf -o /dev/null http://127.0.0.1:${port}/")

      with subtest("the firewall does not open the web port"):
          machine.fail("iptables -S nixos-fw | grep -- '--dport ${port} '")
    '';
}
