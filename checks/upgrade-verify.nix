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
      # judging a generation the script did not ask it to.
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
    };

  testScript = ''
    STATE = "/var/lib/nixos-deploy"
    METRICS = "/var/lib/prometheus-node-exporter/nixos_verify.prom"


    def metric(name):
        """One gauge out of the textfile the node exporter would scrape."""
        out = machine.succeed(
            "grep -E '^{}\\{{' {} | awk '{{print $NF}}'".format(name, METRICS)
        ).strip()
        assert out, "metric {} was not written".format(name)
        return out


    def arm(staged, rolled_back_ago=None):
        """Put the state dir in a known shape, then run verification.

        `staged` is what nixos-upgrade will claim to have staged - None leaves
        no record at all, which is how a host that has not upgraded since this
        landed looks, and how any hand-applied generation looks.
        """
        machine.succeed("mkdir -p {}".format(STATE))
        machine.succeed("rm -f {}/verified-system {}/automation-staged".format(STATE, STATE))

        # Empty and fresh: nothing was failing before, so the canary counts as
        # a new failure and the age guards are satisfied.
        machine.succeed(": > {}/failed-units-baseline".format(STATE))

        if staged is not None:
            machine.succeed("echo {} > {}/automation-staged".format(staged, STATE))

        if rolled_back_ago is None:
            machine.succeed("rm -f {}/last-rollback".format(STATE))
        else:
            machine.succeed(
                "expr $(date +%s) - {} > {}/last-rollback".format(rolled_back_ago, STATE)
            )

        machine.succeed("journalctl --rotate && journalctl --vacuum-time=1s")
        # Verification exits non-zero whenever it refuses, by design - the
        # refusal is the result, not an error.
        machine.fail("systemctl start nixos-upgrade-verify.service")
        return machine.succeed("journalctl -u nixos-upgrade-verify.service --no-pager")


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

    with subtest("a healthy staged generation is blessed"):
        machine.succeed("systemctl reset-failed cg-verify-canary.service")
        machine.succeed("systemctl start nixos-upgrade-verify.service")

        assert metric("nixos_verify_result") == "1"
        assert metric("nixos_verify_manual_generation") == "0"
        assert machine.succeed("cat {}/verified-system".format(STATE)).strip() == current

    with subtest("a blessed generation is not judged twice"):
        # The guard that lets every trigger fire freely. Without it, adding
        # ExecStopPost would mean re-judging a generation on every upgrade.
        machine.fail("systemctl start cg-verify-canary.service")
        machine.succeed("systemctl start nixos-upgrade-verify.service")
        journal = machine.succeed("journalctl -u nixos-upgrade-verify.service --no-pager")
        assert "already verified" in journal, journal
  '';
}
