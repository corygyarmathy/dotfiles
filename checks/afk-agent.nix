# The AFK agent's unit: every parameter supplied, every secret a path, and the
# kill switch removing what it switched on.
#
# The binary's own behaviour is tested offline in its own repository. What only
# this repository can get wrong is the wiring - a parameter the module forgot,
# a credential that does not arrive, a secret that leaks into the unit's
# environment - and the binary refuses to start on the first two. So the VM
# boots the unit for real and asserts how far it gets: past every parameter,
# the store opened, and on to its first request to GitHub, which the sandbox
# has no network for. A usage error would end the run earlier and with a
# different exit status.
#
# The App key is a real, throwaway RSA key generated at build time rather than
# a stub string, because the binary parses the key before it asks GitHub
# anything, and a stub would fail there instead - earlier than the property
# under test. The other credentials are ./stub-secrets.nix fixtures; the unit
# takes all three through `LoadCredential`, which systemd reads as root, so
# there is no per-secret ownership for a `private` fixture to catch.
{ pkgs, lib, ... }:
let
  appKey = pkgs.runCommand "afk-agent-test-app-key" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    openssl genrsa -out $out 2048
  '';

  opencodeKey = "stub-opencode-key-VALUE-MUST-NOT-LEAK";
  ntfyToken = "stub-ntfy-token-VALUE-MUST-NOT-LEAK";
in
{
  name = "afk-agent";

  nodes = {
    enabled =
      { lib, ... }:
      {
        imports = [
          ../modules/services/afk-agent.nix
          # The unit publishes to this host's ntfy and asserts it is enabled.
          # Its option defaults are what production reads; the server itself
          # does not have to answer for anything asserted here.
          ../modules/services/ntfy.nix
          # ntfy asserts the proxy is on, and only the option has to exist for
          # that: the real module wants a certificate email and a DNS token.
          {
            options.cg.service.reverse-proxy.enable = lib.mkOption { default = true; };
          }
          (import ./stub-secrets.nix {
            secrets."opencode/api-key" = opencodeKey;
            secrets."monitoring/ntfy/alerts-token" = ntfyToken;
          })
        ];

        networking.hostName = "afk-enabled";
        system.stateVersion = "24.11";

        sops.secrets."gh-ci/afk-agent-app-private-key".path = lib.mkForce "${appKey}";

        # Declared, not run: the server does not have to be up for the agent's
        # unit to be wired to it.
        cg.service.ntfy.enable = true;
        systemd.services.ntfy-sh.enable = false;

        # homelab01's values, so the check evaluates what production runs.
        cg.service.afk-agent = {
          enable = true;
          repo = "corygyarmathy/dotfiles";
          appId = "4882603";
          workers = 2;
          poll = "1m";
          lease = "2h";
          retry = "15m";
          maxAttempts = 3;
          tokenWait = "1m";
          tokens = { };
          budget = {
            age = "5m";
            threshold = 90;
          };
          notifyTopic = "afk-agent";
          tiers = [
            {
              name = "review";
              models = [
                "opencode-go/deepseek-v4-pro"
                "opencode-go/glm-5.3"
              ];
            }
          ];
          review = {
            tier = "review";
            needs = [ "tool_call" ];
          };
          modelAttempts = 2;
          tierWait = "1h";
          catalogueAge = "24h";
          maxMemory = "4G";
        };
      };

    # The switch off. No stub secrets: declaring none when disabled is part of
    # what is asserted, and a stub for an undeclared name would pass silently.
    disabled = {
      imports = [ ../modules/services/afk-agent.nix ];
      networking.hostName = "afk-disabled";
      system.stateVersion = "24.11";
    };
  };

  testScript = ''
    start_all()

    with subtest("the unit gets past every parameter to its first request to GitHub"):
        # A start that fails, and is meant to: the VM has no network. Waiting
        # on the result of the first attempt rather than on a state, because
        # Restart= puts the unit back to activating a minute later.
        enabled.wait_until_succeeds(
            "test \"$(systemctl show -p ExecMainStatus --value afk-agent.service)\" != 0",
            timeout=120,
        )
        status = enabled.succeed("systemctl show -p ExecMainStatus --value afk-agent.service").strip()
        journal = enabled.succeed("journalctl -u afk-agent.service --no-pager")
        assert status == "1", f"exit {status}, not a runtime failure - 2 is a usage error:\n{journal}"
        assert "api.github.com" in journal, f"the run never reached GitHub:\n{journal}"

        # Opened before GitHub is asked anything, so its presence says the
        # store path was supplied and writable under the hardening.
        enabled.succeed("test -f /var/lib/afk-agent/state.db")

    with subtest("opencode's credentials are provisioned from the key"):
        auth = "/var/lib/afk-agent/.local/share/opencode/auth.json"
        assert enabled.succeed(f"stat -c '%U %a' {auth}").strip() == "afk-agent 600"
        key = enabled.succeed(f"${pkgs.jq}/bin/jq -r '.\"opencode-go\".key' {auth}").strip()
        assert key == "${opencodeKey}", "auth.json does not carry the opencode key"

    with subtest("opencode finds the agent's skills under its $HOME"):
        enabled.succeed("runuser -u afk-agent -- test -r /var/lib/afk-agent/.agents/skills/implement/SKILL.md")

    with subtest("the enrolment is a file the review tier resolves in"):
        env = enabled.succeed("systemctl show -p Environment --value afk-agent.service")
        enrolment = next(v.split("=", 1)[1] for v in env.split() if v.startswith("AFK_ENROLMENT="))
        enabled.succeed(
            f"${pkgs.jq}/bin/jq -e '.tiers | map(select(.name == \"review\")) | .[0].models | length == 2' {enrolment}"
        )

    with subtest("no secret is in the unit's environment, the journal, or a command line"):
        for value in ["${opencodeKey}", "${ntfyToken}", "PRIVATE KEY"]:
            assert value not in env, "a credential value is in the unit's environment"
            assert value not in journal, "a credential value was logged"
        # Every secret parameter is a path into the credentials directory.
        # systemd reports the `%d` specifier expanded or not depending on its
        # version, so accept either spelling of the same directory.
        values = dict(v.split("=", 1) for v in env.split() if "=" in v)
        for name in ["AFK_APP_KEY", "AFK_BUDGET_KEY", "AFK_NOTIFY_KEY"]:
            value = values.get(name, "")
            assert value.startswith(("%d/", "/run/credentials/afk-agent.service/")), (
                f"{name} is not a credential path: {value!r}"
            )
        # The last character bracketed, or grep finds the literal in its own
        # command line and the assertion is about itself.
        enabled.fail(
            "grep -a -e '${lib.removeSuffix "K" opencodeKey}[K]' -e '${lib.removeSuffix "K" ntfyToken}[K]' /proc/[0-9]*/cmdline"
        )

    with subtest("the kill switch leaves nothing behind"):
        disabled.wait_for_unit("multi-user.target")
        disabled.fail("systemctl cat afk-agent.service")
        disabled.fail("id afk-agent")
        disabled.fail("test -e /var/lib/afk-agent")
  '';
}
