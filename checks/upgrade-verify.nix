# Rollback refuses generations nobody staged, and does not refuse the ones it
# staged.
#
# This is the only test here whose subject is a decision rather than a service.
# The reason it earns a VM is that both ways of getting this wrong are silent.
# Too eager and it reverts a change someone applied by hand while they are
# still typing; too shy and `rollback.enable` is cosmetic, every generation
# gets excused, and the safety net reports for months without ever once being
# capable of acting. Neither shows up in a build, and neither shows up in
# production until the night it matters.
#
# So the interesting assertion is not "a bad generation is refused". It is that
# execution reaches a *later* rung of the guard ladder for a staged generation
# than for a hand-applied one. Each subtest below pins the refusal to a
# specific rung and checks the journal names that rung, which is what
# distinguishes a working guard from one that happens to refuse everything.
#
# No rollback is ever performed. Subtest B stops at the cooldown rung by
# writing a fresh `last-rollback` stamp, which is deterministic - relying on
# the VM having only one generation would prove the same thing by accident and
# break the day the harness stages two.
{
  name = "upgrade-verify";

  nodes.machine =
    { pkgs, lib, ... }:
    {
      imports = [ ../modules/nixos/upgrade-verify.nix ];

      # upgrade-verify asserts on this, because it hangs its baseline off
      # nixos-upgrade.service. The flake ref is never resolved: the timer is
      # detached below so the upgrade itself never runs, which it could not do
      # anyway inside a network-less build sandbox.
      system.autoUpgrade = {
        enable = true;
        flake = "/dev/null#nothing";
      };

      # Both timers detached rather than disabled, so the units themselves stay
      # exactly as a host would have them - this test reads their wiring. What
      # is not wanted is either one firing underneath a subtest and blessing or
      # judging a generation the script did not ask it to. The verify timer is
      # started by hand, once, by the schedule subtest that runs last.
      systemd.timers.nixos-upgrade.wantedBy = lib.mkForce [ ];
      systemd.timers.nixos-upgrade-verify.wantedBy = lib.mkForce [ ];

      cg.upgrade-verify = {
        enable = true;

        # The behaviour under test is the refusal ladder, which is reached
        # identically whether or not rollback is armed - except that with it
        # off, every path short-circuits at "reporting only" and the ladder is
        # never exercised at all. On, therefore, which is also the
        # configuration this test exists to de-risk.
        rollback.enable = true;

        # Defaults are 120s and 300s, chosen so a real host lets a service
        # crash-loop a few times before judging it. Nothing here is racing a
        # restart, and the globalTimeout is 600s.
        settleSeconds = 1;
        settleTimeoutSeconds = 10;

        # The timer stays detached (below), so this never fires on its own -
        # the "schedule verifies a generation nothing announced" subtest starts
        # the timer by hand at the end and needs a cadence faster than the
        # production `hourly`. Every second stays far inside the three minute
        # OnBootSec that the subtest asserts was not what fired.
        recheckSchedule = "*:*:*";
      };

      # Stands in for a service that came up broken under a new generation.
      # Started by hand in the test, so its failure is timed rather than
      # racing the boot transaction.
      systemd.services.cg-verify-canary = {
        description = "Deliberately failing unit, to give verification something to find";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.coreutils}/bin/false";
        };
      };

      # A second kind of broken: Restart= keeps re-offering a unit that keeps
      # dying. With restarts slower than the start limit this never reaches
      # the terminal "failed" state - it sits in "activating (auto-restart)",
      # which is exactly why it needs its own subtest. RestartSec is long so
      # the state is deterministic: verification always finds it mid-wait,
      # never mid-crash and never start-limit-tripped into failed. Not
      # Type=oneshot: systemd refuses to combine that with Restart=.
      systemd.services.cg-verify-crashlooper = {
        description = "Unit stuck in systemd's auto-restart state";
        serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.coreutils}/bin/false";
          Restart = "always";
          RestartSec = "30s";
        };
      };
    };

  # A second machine, because this is the only subtest that lets the rollback
  # actually happen. It rewrites the running system, so it cannot share a node
  # with subtests that assume theirs stands still.
  nodes.rollback =
    { pkgs, lib, ... }:
    {
      imports = [ ../modules/nixos/upgrade-verify.nix ];

      system.autoUpgrade = {
        enable = true;
        flake = "/dev/null#nothing";
      };

      systemd.timers.nixos-upgrade.wantedBy = lib.mkForce [ ];
      systemd.timers.nixos-upgrade-verify.wantedBy = lib.mkForce [ ];

      # The VM boots its kernel directly, and grub-install cannot write to its
      # ext2 disk ("will not proceed with blocklists"). That matters here and
      # nowhere else in this file, because rollback is the only path that runs
      # switch-to-configuration: bootloader installation happens *before*
      # activation, so a failure there aborts the switch and the rollback moves
      # the profile without ever activating it. Disabled so the test measures
      # this module rather than the harness.
      #
      # Worth knowing that the same ordering applies on a real host: if
      # installing the bootloader fails there, a rollback will report success
      # while leaving the bad generation running.
      boot.loader.grub.enable = lib.mkForce false;

      cg.upgrade-verify = {
        enable = true;
        rollback.enable = true;
        settleSeconds = 1;
        settleTimeoutSeconds = 10;
        # Nothing fires on its own here; the subtest owns the timing.
        recheckSchedule = null;
      };

      systemd.services.cg-verify-canary = {
        description = "Deliberately failing unit, to give verification something to find";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.coreutils}/bin/false";
        };
      };

      # A second system closure to roll back *from*. A specialisation is the
      # only way to get a genuinely different toplevel in here: the build
      # sandbox has no network, so the second generation has to come out of the
      # same build as the first. What differs does not matter - only that the
      # store path does.
      specialisation.alt.configuration = {
        environment.etc."cg-alt-generation".text = "second generation";
      };
    };

  # A third machine, where installing the bootloader always fails. That is the
  # fault behind the defect under test: switch-to-configuration installs the
  # bootloader *before* it activates, so a failure there leaves the profile
  # moved and nothing else done, and the old code read the moved profile as
  # proof of a successful rollback.
  #
  # Injected directly rather than by leaving grub enabled and letting the VM's
  # grub-install fail on its ext2 disk. That does reproduce it - it is how the
  # defect was found - but only in some orderings, and it would quietly stop
  # testing anything the day nixpkgs changes the test disk.
  nodes.bootfail =
    { pkgs, lib, ... }:
    {
      imports = [ ../modules/nixos/upgrade-verify.nix ];

      system.autoUpgrade = {
        enable = true;
        flake = "/dev/null#nothing";
      };

      systemd.timers.nixos-upgrade.wantedBy = lib.mkForce [ ];
      systemd.timers.nixos-upgrade-verify.wantedBy = lib.mkForce [ ];

      boot.loader.grub.enable = lib.mkForce false;
      system.build.installBootLoader = lib.mkForce (
        pkgs.writeShellScript "cg-failing-bootloader-install" ''
          echo "Failed to install bootloader" >&2
          exit 1
        ''
      );

      cg.upgrade-verify = {
        enable = true;
        rollback.enable = true;
        settleSeconds = 1;
        settleTimeoutSeconds = 10;
        recheckSchedule = null;
      };

      systemd.services.cg-verify-canary = {
        description = "Deliberately failing unit, to give verification something to find";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.coreutils}/bin/false";
        };
      };

      specialisation.alt.configuration = {
        environment.etc."cg-alt-generation".text = "second generation";
      };
    };

  testScript = ''
    STATE = "/var/lib/nixos-deploy"
    METRICS = "/var/lib/prometheus-node-exporter/nixos_verify.prom"


    def metric(name, node=None):
        """One gauge out of the textfile the node exporter would scrape."""
        node = node or machine
        out = node.succeed(
            "grep -E '^{}\\{{' {} | awk '{{print $NF}}'".format(name, METRICS)
        ).strip()
        assert out, "metric {} was not written".format(name)
        return out


    def arm(staged, rolled_back_ago=None, node=None):
        """Put the state dir in a known shape, then run verification.

        `staged` is what nixos-upgrade will claim to have staged - None leaves
        no record at all, which is how a host that has not upgraded since this
        landed looks, and how any hand-applied generation looks.
        """
        node = node or machine
        node.succeed("mkdir -p {}".format(STATE))
        node.succeed("rm -f {}/verified-system {}/automation-staged".format(STATE, STATE))

        # Empty and fresh: nothing was failing before, so the canary counts as
        # a new failure and the age guards are satisfied.
        node.succeed(": > {}/failed-units-baseline".format(STATE))

        if staged is not None:
            node.succeed("echo {} > {}/automation-staged".format(staged, STATE))

        if rolled_back_ago is None:
            node.succeed("rm -f {}/last-rollback".format(STATE))
        else:
            node.succeed(
                "expr $(date +%s) - {} > {}/last-rollback".format(rolled_back_ago, STATE)
            )

        node.succeed("journalctl --rotate && journalctl --vacuum-time=1s")
        # Verification exits non-zero whenever it refuses *and* when it acts -
        # the outcome is the result, not an error.
        node.fail("systemctl start nixos-upgrade-verify.service")
        return node.succeed("journalctl -u nixos-upgrade-verify.service --no-pager")


    machine.wait_for_unit("multi-user.target")
    current = machine.succeed("readlink -f /run/current-system").strip()

    with subtest("verification is triggered on both upgrade outcomes"):
        # Regression guard for the ExecStartPost -> ExecStopPost fix: systemd
        # skips ExecStartPost when ExecStart fails, which silently skipped
        # verification in exactly the case it is wanted.
        hooks = machine.succeed("systemctl show nixos-upgrade -p ExecStartPost -p ExecStopPost")
        assert "nixos-upgrade-verify.service" in hooks, hooks
        assert "nixos-upgrade-record-staged" in hooks, hooks

        # Asserted per-line rather than on the blob: an unrelated ExecStartPost
        # arriving later is fine, the verify trigger living in one is not.
        start_post = [ln for ln in hooks.splitlines() if ln.startswith("ExecStartPost=")]
        assert not any("nixos-upgrade-verify" in ln for ln in start_post), (
            "verification must not hang off ExecStartPost:\n" + hooks
        )

    # Give verification something to find, for the two subtests that need a
    # generation to judge as unhealthy.
    machine.fail("systemctl start cg-verify-canary.service")
    machine.succeed("systemctl is-failed cg-verify-canary.service")

    with subtest("a hand-applied generation is reported but never rolled back"):
        journal = arm(staged=None)

        assert "applied by hand" in journal, journal
        assert metric("nixos_verify_result") == "0"
        assert metric("nixos_verify_manual_generation") == "1"
        assert metric("nixos_verify_rolled_back") == "0"

        # The point of the whole exercise: the running generation survived.
        assert machine.succeed("readlink -f /run/current-system").strip() == current
        machine.succeed("test ! -e {}/last-rollback".format(STATE))

    with subtest("a staged generation reaches the guards beyond provenance"):
        # Same unhealthy machine, the only difference being who staged it. If
        # the provenance guard were over-firing, this would refuse for the same
        # reason as above and rollback would be dead on every host.
        journal = arm(staged=current, rolled_back_ago=60)

        assert "applied by hand" not in journal, journal
        assert "cooldown" in journal, journal
        assert metric("nixos_verify_manual_generation") == "0"
        assert metric("nixos_verify_result") == "0"
        assert metric("nixos_verify_rolled_back") == "0"

    with subtest("a unit stuck restarting counts even though systemd calls it activating"):
        # Regression guard for 2026-08-26: alertmanager-ntfy crash-looped all
        # night in "activating (auto-restart)", invisible to list-units
        # --failed, so verification judged the generation on the wrong
        # evidence. The canary is cleared first so the crashlooper is the only
        # thing wrong and the attribution in the journal is exact.
        machine.succeed("systemctl reset-failed cg-verify-canary.service")
        # Unlike the oneshot canary above, a simple service's start job
        # completes when the process is SPAWNED - so `systemctl start` returns
        # while the fixture is still "running", and systemd only moves it to
        # auto-restart once it reaps the child and schedules the restart.
        # Reading SubState once, straight after start, is therefore a race:
        # it usually wins on an idle machine and lost in CI on 2026-08-27,
        # reporting "running" and failing a test about the state after that.
        # Waiting for the state asserts the same property without the race -
        # the fixture must be in auto-restart before verification looks at it.
        machine.succeed("systemctl start cg-verify-crashlooper.service")
        machine.wait_until_succeeds(
            "systemctl show cg-verify-crashlooper -p SubState --value"
            " | grep -qx auto-restart"
        )

        journal = arm(staged=current, rolled_back_ago=60)

        assert "cg-verify-crashlooper" in journal, journal
        assert metric("nixos_verify_result") == "0"

        machine.succeed("systemctl stop cg-verify-crashlooper.service")
        # No reset-failed here: a unit stopped out of auto-restart goes
        # inactive, never through failed, so there is nothing to reset.

    with subtest("a healthy staged generation is blessed"):
        # The crashlooper subtest above already cleared the canary, so
        # everything is clean here by construction.
        machine.succeed("systemctl start nixos-upgrade-verify.service")

        assert metric("nixos_verify_result") == "1"
        assert metric("nixos_verify_manual_generation") == "0"
        assert machine.succeed("cat {}/verified-system".format(STATE)).strip() == current

    with subtest("both triggers are armed on one timer"):
        timer = machine.succeed(
            "systemctl show nixos-upgrade-verify.timer -p TimersMonotonic -p TimersCalendar"
        )
        # systemd renders OnBootSec= back as OnBootUSec.
        assert "OnBootUSec=3min" in timer, timer
        assert "OnCalendar=" in timer, timer

    with subtest("a blessed generation is not judged twice"):
        # The guard that lets every trigger fire freely. Without it, adding
        # ExecStopPost would mean re-judging a generation on every upgrade.
        machine.fail("systemctl start cg-verify-canary.service")
        machine.succeed("systemctl start nixos-upgrade-verify.service")
        journal = machine.succeed("journalctl -u nixos-upgrade-verify.service --no-pager")
        assert "already verified" in journal, journal

    with subtest("a failed upgrade run does not itself condemn the generation"):
        # Regression guard for 2026-08-26: the switch failed, nixos-upgrade
        # entered the failed state before its ExecStopPost triggered
        # verification, and verification counted the trigger unit as the new
        # failure - a healthy generation reported as broken. Starting
        # nixos-upgrade here reproduces exactly that: its flake ref is
        # /dev/null, so the run fails, and ExecStopPost both records the staged
        # generation (unchanged - the rebuild failed before it staged anything)
        # and starts verification, which must now bless what is running.
        machine.succeed("systemctl reset-failed cg-verify-canary.service")
        # Remove both the bless record and the metrics, so the assertions below
        # cannot pass on values left behind by an earlier subtest - the verify
        # run about to be triggered must write them afresh.
        machine.succeed("rm -f {}/verified-system {}".format(STATE, METRICS))
        # A real host always has a system profile for the ExecStopPost
        # record-staged hook to read the staged generation off; a bare VM
        # boots straight from the store without one, so seed it the way the
        # rollback subtest does.
        machine.succeed("nix-env -p /nix/var/nix/profiles/system --set {}".format(current))
        machine.fail("systemctl start nixos-upgrade.service")
        machine.succeed("systemctl is-failed nixos-upgrade.service")

        # Verification is started by the upgrade's own ExecStopPost, as in
        # production, but asynchronously (--no-block). Poll for the bless
        # record instead of sleeping a fixed window: faster, and a real
        # assertion - if the trigger does not fire, this times out.
        machine.wait_for_file("{}/verified-system".format(STATE), timeout=60)

        assert metric("nixos_verify_result") == "1"
        assert metric("nixos_verify_manual_generation") == "0"
        assert (
            machine.succeed("cat {}/verified-system".format(STATE)).strip() == current
        )
        machine.succeed("systemctl reset-failed nixos-upgrade.service")

    with subtest("the schedule verifies a generation nothing announced"):
        # Nothing here ever starts verification on its own: no upgrade has run,
        # and the timer is detached (see the node definition) so the earlier
        # subtests control their own timing. Starting it by hand is the point -
        # the calendar entry fires, not anything the subtests above did. The
        # only other trigger is OnBootSec at three minutes, so the uptime
        # assertion pins this to the calendar rather than to verification
        # working at all.
        #
        # The failed-upgrade subtest just above leaves a staged record and a
        # bless record on disk; both must go or the calendar run would report
        # manual=0 and have nothing to bless.
        machine.succeed("rm -f {}/verified-system {}/automation-staged".format(STATE, STATE))
        machine.succeed("systemctl start nixos-upgrade-verify.timer")
        machine.wait_for_file("{}/verified-system".format(STATE), timeout=100)
        machine.succeed("systemctl stop nixos-upgrade-verify.timer")

        uptime = float(machine.succeed("cut -d' ' -f1 /proc/uptime").strip())
        assert uptime < 170, "OnBootSec may have fired; uptime was {}".format(uptime)

        blessed = machine.succeed("cat {}/verified-system".format(STATE)).strip()
        assert blessed == current, (blessed, current)

        # With no staged record, provenance reads the running generation as
        # hand-applied - correctly, and harmlessly, since a healthy generation
        # is never a rollback candidate anyway.
        assert metric("nixos_verify_manual_generation") == "1"

    with subtest("a staged generation that came up broken is really rolled back"):
        # Every other subtest pins a *refusal*. This one is the code that runs
        # at 04:00 on a real server: nix-env --rollback, then the rolled-back
        # profile's own switch-to-configuration. Nothing else exercises it, and
        # a rollback that cannot roll back is the one failure the report-only
        # period cannot reveal.
        rollback.wait_for_unit("multi-user.target")
        gen1 = rollback.succeed("readlink -f /run/current-system").strip()
        alt = rollback.succeed("readlink -f /run/current-system/specialisation/alt").strip()
        assert alt != gen1, (alt, gen1)

        # The VM boots straight from the store, so the system profile starts
        # with no generations at all - unlike a real host, where the running
        # system is already generation N. Seed it with what is running, or
        # there is nothing to roll back *to* and the ladder would refuse at the
        # "no previous generation" rung for reasons that are pure harness.
        rollback.succeed("nix-env -p /nix/var/nix/profiles/system --set {}".format(gen1))

        # Install and activate the second generation the way nixos-upgrade
        # would - profile first, then activate what the profile now points at.
        rollback.succeed("nix-env -p /nix/var/nix/profiles/system --set {}".format(alt))
        rollback.succeed("{}/bin/switch-to-configuration switch".format(alt))
        assert rollback.succeed("readlink -f /run/current-system").strip() == alt

        generations = int(
            rollback.succeed(
                "nix-env -p /nix/var/nix/profiles/system --list-generations | wc -l"
            ).strip()
        )
        assert generations >= 2, generations

        # ...and let it come up broken.
        rollback.fail("systemctl start cg-verify-canary.service")

        journal = arm(staged=alt, node=rollback)
        assert "Rolling back" in journal, journal

        # The claim, three ways: the profile moved, the running system moved,
        # and the bootloader default moved with it. Checking only the profile
        # would pass on a rollback that never activated anything.
        assert rollback.succeed("readlink -f /nix/var/nix/profiles/system").strip() == gen1
        assert rollback.succeed("readlink -f /run/current-system").strip() == gen1
        rollback.succeed("test ! -e /etc/cg-alt-generation")

        assert metric("nixos_verify_rolled_back", node=rollback) == "1"
        assert metric("nixos_verify_rollback_failed", node=rollback) == "0"
        assert metric("nixos_verify_result", node=rollback) == "0"
        assert metric("nixos_verify_manual_generation", node=rollback) == "0"
        rollback.succeed("test -e {}/last-rollback".format(STATE))

        # The switch really re-activated things rather than only moving
        # symlinks: the unit that was failing under the abandoned generation
        # is no longer failing under this one.
        rollback.succeed("systemctl is-failed cg-verify-canary.service || true")
        rollback.fail("systemctl is-failed --quiet cg-verify-canary.service")

        # And the rollback cannot cascade. The generation reverted *to* was
        # never the staged one, so it reads as hand-applied and is exempt from
        # rollback no matter what it does - which is the property the cooldown
        # used to be solely responsible for. (The cooldown rung itself is
        # covered above, on a node that has not moved underneath it.)
        rollback.succeed("rm -f {}/verified-system".format(STATE))
        rollback.succeed("systemctl start nixos-upgrade-verify.service")
        assert metric("nixos_verify_result", node=rollback) == "1"
        assert metric("nixos_verify_manual_generation", node=rollback) == "1"
        assert metric("nixos_verify_rolled_back", node=rollback) == "0"
        assert rollback.succeed("cat {}/verified-system".format(STATE)).strip() == gen1

    with subtest("a rollback that cannot activate says so instead of claiming success"):
        # nix-env --rollback moves the profile, then switch-to-configuration
        # installs the bootloader *before* activating. When that install fails
        # it exits early, so the profile has moved and nothing else has. The
        # old code read the moved profile as proof and reported a successful
        # rollback while the failed generation kept running.
        bootfail.wait_for_unit("multi-user.target")
        running = bootfail.succeed("readlink -f /run/current-system").strip()
        alt = bootfail.succeed("readlink -f /run/current-system/specialisation/alt").strip()
        assert alt != running, (alt, running)

        # Generations built through the profile rather than by activating,
        # because activating is precisely what does not work on this node.
        # Leaves the profile on what is running, with somewhere to roll back to.
        bootfail.succeed("nix-env -p /nix/var/nix/profiles/system --set {}".format(alt))
        bootfail.succeed("nix-env -p /nix/var/nix/profiles/system --set {}".format(running))

        # ...and give verification a reason to want the rollback.
        bootfail.fail("systemctl start cg-verify-canary.service")

        journal = arm(staged=running, node=bootfail)

        # The fault injector really fired, rather than the rollback failing
        # for some unrelated reason that would make the rest vacuous.
        assert "Failed to install bootloader" in journal, journal

        assert "ROLLBACK DID NOT TAKE" in journal, journal
        assert bootfail.succeed("readlink -f /run/current-system").strip() == running
        assert bootfail.succeed("readlink -f /nix/var/nix/profiles/system").strip() == alt

        assert metric("nixos_verify_rollback_failed", node=bootfail) == "1"
        assert metric("nixos_verify_rolled_back", node=bootfail) == "0"
        assert metric("nixos_verify_result", node=bootfail) == "0"

        # No stamp: nothing moved, so nothing should be held off by a cooldown.
        bootfail.succeed("test ! -e {}/last-rollback".format(STATE))
  '';
}
