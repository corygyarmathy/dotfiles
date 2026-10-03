# checks/ntfy.nix
#
# Behaviour test for the ntfy server as cg.service.ntfy ships it.
#
# The module overrides upstream's DynamicUser with a static ntfy-sh user so
# that the documented bootstrap (`sudo -u ntfy-sh ntfy user add ...`) can
# reach the auth database. The other tests never start this unit: `monitoring`
# runs the upstream module directly and `afk-agent` disables the server. So
# when nixpkgs stopped declaring the user, the server failed at step USER on
# homelab01's nightly switch and nothing here noticed. This boots the module
# and walks the bootstrap the header documents.
{
  name = "ntfy";

  nodes.machine =
    { lib, ... }:
    {
      imports = [
        ../modules/services/ntfy.nix
        # ntfy asserts the proxy is on; only the option has to exist for that,
        # since the server binds loopback and is exercised from there.
        {
          options.cg.service.reverse-proxy.enable = lib.mkOption { default = true; };
        }
      ];

      networking.hostName = "ntfy";
      system.stateVersion = "24.11";

      cg.service.ntfy.enable = true;
    };

  testScript =
    { nodes, ... }:
    let
      port = toString nodes.machine.cg.service.ntfy.port;
    in
    ''
      machine.wait_for_unit("ntfy-sh.service")
      machine.wait_for_open_port(${port})

      with subtest("the server runs as the static user the bootstrap targets"):
          user = machine.succeed("systemctl show -P User ntfy-sh.service").strip()
          assert user == "ntfy-sh", f"ntfy-sh runs as {user!r}"
          machine.succeed("getent passwd ntfy-sh")

      with subtest("the documented bootstrap creates a user the server accepts"):
          machine.succeed(
              "NTFY_PASSWORD=test-password sudo -E -u ntfy-sh "
              "ntfy user add --role=admin cory --config /etc/ntfy/server.yml"
          )
          # deny-all by default: anonymous is refused, the new account is not.
          machine.fail("curl -sf http://127.0.0.1:${port}/alerts/json?poll=1")
          machine.succeed("curl -sf -u cory:test-password http://127.0.0.1:${port}/alerts/json?poll=1")
    '';
}
