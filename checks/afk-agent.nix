# The kill switch, and the plumbing it switches.
#
# ADR 0004 §7 says the AFK pipeline is a real NixOS module rather than a script
# someone remembers to run, so that turning it off in an emergency is one
# boolean. That claim is only worth anything if the boolean actually removes
# the units - and "the module evaluates" cannot tell the difference between a
# `lib.mkIf` that guards everything and one that guards half of it. So this
# boots the module both ways and looks at the running system: two nodes, one
# with the switch on and one with it off.
#
# The other half is the plumbing the runner is handed. What this file owns is
# everything around the logic - that the unit is reached by the timer rather
# than at boot, that every credential it declares arrives, and that the
# toolchain it drives is on its PATH. The runner asserts exactly those before
# it polls anything, which is what lets a VM with no network still prove them.
#
# The runner's own behaviour is not testable here and is not attempted: it
# talks to the GitHub API and clones a repository, and the sandbox has neither.
# That is checks/afk-agent-runner.nix, which drives this same script against a
# mocked `gh` and a fixture origin. Here the run is expected to fail at its
# first outbound call, and the assertion is about how far it got first.
#
# The credentials are plaintext fixtures via ./stub-secrets.nix; sops cannot
# decrypt in the sandbox, and no real value belongs in a test either way. They
# are ordinary store fixtures rather than `private` ones because the module
# hands them over with `LoadCredential`, which systemd reads as root before the
# unit drops to its own user - so there is no per-secret ownership to get
# wrong, and nothing for a `private` fixture to catch.
{
  name = "afk-agent";

  nodes = {
    # The switch on.
    enabled =
      { ... }:
      {
        imports = [
          ../modules/services/afk-agent.nix

          # ntfy.nix and monitoring.nix are imported for their option
          # declarations only: the runner reads the ntfy port and the push
          # lane's topic from the modules that own them (item 9, #176), so a
          # node that boots this module needs both declared or the eval
          # refuses. What is read here is those options' defaults, the same
          # values production gets on homelab01 - neither stack has to be
          # running for the module to name where it would publish.
          ../modules/services/ntfy.nix
          ../modules/services/monitoring/monitoring.nix

          (import ./stub-secrets.nix {
            secrets."gh-ci/afk-agent-app-private-key" = "stub-app-key-VALUE-MUST-NOT-BE-LOGGED";
            secrets."opencode/api-key" = "stub-opencode-key-VALUE-MUST-NOT-BE-LOGGED";
            secrets."opencode/username" = "stub-opencode-user-VALUE-MUST-NOT-BE-LOGGED";
            secrets."monitoring/ntfy/alerts-token" = "stub-ntfy-token-VALUE-MUST-NOT-BE-LOGGED";
          })
        ];

        networking.hostName = "afk-enabled";
        system.stateVersion = "24.11";

        cg.service.afk-agent = {
          enable = true;

          # Not the default, deliberately. The default polls every quarter hour
          # and this test asserts that nothing has run the service yet, which a
          # timer firing mid-run would falsify - rarely, and only for whoever
          # happened to push across a quarter-hour boundary. A date the VM will
          # never reach makes "inactive" mean "the timer has not fired", which
          # is the property under test; that the default is a sane calendar
          # expression is the module's business, not this test's.
          schedule = "2100-01-01 00:00:00";
        };
      };

    # The switch off. No stub secrets: a module that declares none when
    # disabled is part of what is being asserted, and stubbing names nothing
    # declares would land the override on nothing and pass silently
    # (./stub-secrets.nix says so).
    disabled =
      { ... }:
      {
        imports = [ ../modules/services/afk-agent.nix ];

        networking.hostName = "afk-disabled";
        system.stateVersion = "24.11";
      };
  };

  testScript = ''
    start_all()

    with subtest("the timer is armed, and it - not boot - is what runs the poller"):
        enabled.wait_for_unit("afk-agent.timer")
        assert enabled.succeed("systemctl is-enabled afk-agent.timer").strip() == "enabled"
        enabled.succeed("systemctl list-timers --all | grep -q afk-agent.timer")

        # Nothing wants the service at boot; the timer is its only trigger. If
        # it ever grows an [Install] section, a host that enabled the module
        # would start a coding agent on every boot instead of on the schedule
        # it was given.
        #
        # Asked as "does any target want it" rather than as `systemctl
        # is-enabled`, which answers this one usefully in only one direction.
        # A unit something wants comes back `enabled` - which is why the timer
        # above can be checked that way - but a NixOS unit with no [Install]
        # section comes back `linked` and exit 1, the same answer a genuinely
        # disabled unit gives. The glob distinguishes them; is-enabled does not.
        wants = enabled.succeed(
            "ls -d /etc/systemd/system/*.wants/afk-agent.service 2>/dev/null || true"
        ).strip()
        assert wants == "", f"something starts the poller without the timer: {wants}"
        state = enabled.succeed("systemctl show -p ActiveState --value afk-agent.service").strip()
        assert state == "inactive", f"the poller ran without the timer firing: {state}"

    with subtest("a run reaches every credential and every tool it requires"):
        # The run fails, and is expected to. Since ADR 0006 it fails a step
        # earlier than it used to: the credential is a GitHub App private key
        # now, the stub above is not one, and the runner mints its token before
        # its first `gh` call rather than reading a bearer token off disk. (Had
        # it got past that, the VM has no network and `gh issue list` would
        # have failed anyway.) Everything asserted below still happens before
        # either point by design - a credential missing or a tool off the PATH
        # should fail on an empty tracker rather than halfway through a ticket
        # that has already been claimed.
        enabled.fail("systemctl start afk-agent.service")
        journal = enabled.succeed("journalctl -u afk-agent.service --no-pager")

        # What to expect is read out of the script the unit actually runs,
        # rather than listed here. Both lists are generated from one attribute
        # set in the module, and a list written out again in this file would
        # quietly stop covering whatever was added to that set next - which is
        # not hypothetical: `diff` joined the toolchain after this test was
        # first written, and a hand-written list would not have noticed.
        script = enabled.succeed(
            "systemctl cat afk-agent.service | sed -n 's/^ExecStart=//p'"
        ).strip()

        def required(directive):
            names = enabled.succeed(
                f"grep '^{directive} ' {script} | cut -d' ' -f2"
            ).split()
            assert names, f"the runner has no {directive} lines at all"
            return names

        for credential in required("require_credential"):
            assert f"credential '{credential}' present" in journal, (
                f"{credential} did not reach the unit:\n{journal}"
            )

        for tool in required("require_tool"):
            assert f"tool '{tool}' present" in journal, f"{tool} is not on the unit's PATH:\n{journal}"

        # It got past the plumbing and into the work. Without this the two
        # loops above would still pass on a runner that asserted its inputs
        # and then did nothing at all.
        assert "polling corygyarmathy/dotfiles" in journal, (
            f"the run never reached the poll:\n{journal}"
        )

    with subtest("the model gets a shell that will run a command"):
        # This is here because its absence cost a live run. opencode spawns
        # `$SHELL` for every bash call the model makes; systemd fills `$SHELL`
        # in from the service account's passwd entry unless the unit says
        # otherwise; and an `isSystemUser` account's passwd shell is `nologin`.
        # So the first real ticket claimed, cloned and isolated, and then every
        # command the agent ran answered "This account is currently not
        # available." - while the runner's own `gh` and `git` calls, which
        # never go through a shell, worked throughout.
        #
        # Two assertions rather than one, because they fail differently. The
        # unit's own `$SHELL` is the fix; `require_shell` firing in the journal
        # is what makes a future regression fail on an empty poll rather than
        # on a ticket that has already been claimed.
        shell = enabled.succeed(
            "systemctl show -p Environment --value afk-agent.service"
            " | tr ' ' '\n' | sed -n 's/^SHELL=//p'"
        ).strip()
        assert shell, "the unit sets no SHELL, so opencode inherits the account's nologin"
        enabled.succeed(f"test -x {shell}")
        enabled.succeed(f"{shell} -c 'exit 0'")

        assert f"shell '{shell}' runs commands" in journal, (
            f"the preflight did not check the shell, so a nologin would reach a claimed ticket:\n{journal}"
        )

        # And the account itself is still not one anybody can log into. The
        # shell is a property of the unit, not a login shell handed to a system
        # account that has no other use for one.
        passwd_shell = enabled.succeed("getent passwd afk-agent | cut -d: -f7").strip()
        assert "nologin" in passwd_shell, (
            f"the fix gave the service account a login shell instead: {passwd_shell}"
        )

    with subtest("a run cannot exhaust the host's memory"):
        # 2026-09-10: a run reached 8.3 GB in one `nix` process and the kernel
        # OOM killer fired globally - `CONSTRAINT_NONE`, the whole machine
        # rather than this cgroup. It picked this unit because it was biggest;
        # it could have picked any service on the host. The ceiling is what
        # makes that a contained failure, and the ticket then ends on the stuck
        # path like any other dead run.
        limit = enabled.succeed(
            "systemctl show -p MemoryMax --value afk-agent.service"
        ).strip()
        assert limit not in ("", "infinity"), (
            f"the unit has no memory ceiling, so a run can still take the host down: {limit}"
        )

        # And the gate does not put it straight back over. `nix flake check`
        # evaluates every output of this flake in one process, which is what
        # overran; the gate builds each check separately, the way ci.yml's
        # matrix does.
        #
        # Matched on the invocation rather than on the phrase. The prompt in
        # this same script names `nix flake check` on purpose - it is what
        # tells the model not to run one - so a bare substring search reads
        # the warning as the offence, which is exactly what it did when this
        # subtest was first written.
        body = enabled.succeed(f"cat {script}")
        assert "step nix flake check" not in body, (
            "the gate runs `nix flake check` again, which is what exhausted the host"
        )
        assert 'nix build --no-link ".#checks.' in body, (
            "the gate no longer builds the checks one at a time"
        )

    with subtest("no credential value reaches the journal"):
        # The unit reads four secrets on every poll. A debug echo left behind
        # in the runner would put a repo-write App key into the system journal,
        # which is exactly the mistake nothing else here would catch. The key
        # is the worse one to lose of the four: unlike the PAT it replaced, it
        # has no expiry date to bound the damage. The ntfy token (item 9,
        # #176) is the newest, and the push credential a phone trusts.
        for value in [
            "stub-app-key-VALUE-MUST-NOT-BE-LOGGED",
            "stub-opencode-key-VALUE-MUST-NOT-BE-LOGGED",
            "stub-opencode-user-VALUE-MUST-NOT-BE-LOGGED",
            "stub-ntfy-token-VALUE-MUST-NOT-BE-LOGGED",
        ]:
            assert value not in journal, "a credential value was logged"

    with subtest("the kill switch leaves nothing behind"):
        disabled.wait_for_unit("multi-user.target")
        disabled.fail("systemctl cat afk-agent.timer")
        disabled.fail("systemctl cat afk-agent.service")

        # The service account too. "Fully stops the pipeline" is the plan's
        # wording (item 4); an idle unit is stopped, a lingering account with a
        # state directory is not.
        disabled.fail("id afk-agent")
        disabled.fail("test -e /var/lib/afk-agent")
  '';
}
