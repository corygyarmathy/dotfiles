# checks/download-root-canary.nix
#
# Behaviour test for the download-root canary
# (modules/services/media-stack/download-root-canary.nix, item 8 of
# docs/plans/deployment-hardening.md).
#
# The canary is a sentinel file primed once per boot in the shared download
# root, statted by a timer, and published to node_exporter's textfile
# collector as download_root_canary_present. Deleting the sentinel by hand and
# seeing the metric report missing is the plan's own "done when" - this test is
# that, in a VM:
#
#   - the sentinel exists after the check has run, and the metric says 1
#   - node_exporter's textfile collector serves the metric (the mkDefault
#     override that leaves the collector off on hosts without ZFS/VPN)
#   - deleting the sentinel and re-checking flips the metric to 0, and the
#     exporter does NOT re-create it - priming is boot-scoped via a /run
#     marker, so a sending service is never handed its sentinel back
#   - clearing the /run marker (a reboot's effect) re-arms the prime, proving
#     the positive half: a healthy boot puts the sentinel in place again
#
# No containers, no network, no Prometheus: the test asserts the unit's file
# output and the node_exporter scrape of it. The alert side is pinned by
# promtool in alert-rules.test.yml (a present sentinel stays silent, a
# sustained 0 matures DownloadRootCanaryMissing after its `for:`).
{
  name = "download-root-canary";

  nodes.machine =
    { lib, ... }:
    {
      imports = [
        ../modules/services/media-stack/media-stack.nix
        ../modules/services/media-stack/download-root-canary.nix
        ../modules/services/monitoring/monitoring.nix
        # Imported so media-stack's tmpfiles condition
        # `!config.cg.service.nas-storage.enable` evaluates; it stays disabled,
        # so the VM's own tmpfiles creates the media tree as a single-box host
        # would.
        ../modules/services/nas-storage.nix
      ];

      networking.hostName = "download-root-canary";
      system.stateVersion = "24.11";

      cg.service.media-stack.enable = true;
      cg.service.media-stack.canary.enable = true;
      cg.service.monitoring.enable = true;

      # media-stack's tmpfiles chowns the media tree to the user/group its
      # options name. Real hosts define coryg somewhere; this minimal VM does
      # not, so without an identity the `d /srv/media/...` rules silently fail
      # and there is nowhere for the sentinel to live. media-stack creates the
      # media group itself.
      users.users.coryg = {
        isNormalUser = true;
        group = "media";
        uid = 1000;
      };

      # Plenty for a node_exporter + canary; the test is not pushing.
      virtualisation.memorySize = 1024;
    };

  testScript = ''
    sentinel = "/srv/media/downloads/.download-root-canary"
    metrics = "/var/lib/prometheus-node-exporter/download_root_canary.prom"
    marker = "/run/download-root-canary-primed"

    # The unit is timer-only by design (no boot-time wantedBy: an unreachable
    # NFS server must not stall boot, and an automount idle-timeout is a
    # smaller first run than a boot-time one). Starting it here is the
    # invocation the assertions read.
    machine.succeed("systemctl start download-root-canary.service")

    with subtest("the sentinel is primed and reported present"):
        machine.succeed(f"test -e {sentinel}")
        machine.succeed(
            f"grep -q 'download_root_canary_present 1' {metrics}"
        )
        machine.succeed(f"test -e {marker}")

    with subtest("node_exporter serves the canary metric (textfile collector wiring)"):
        machine.wait_for_open_port(9100)
        # Written to a file rather than piped into grep: the test driver
        # runs commands under `pipefail`, and `grep -q` exiting at the first
        # match hands curl an EPIPE. Same shape as checks/monitoring.nix.
        machine.wait_until_succeeds(
            "curl -sf -o /tmp/node-metrics http://localhost:9100/metrics "
            "&& grep -q download_root_canary_present /tmp/node-metrics",
            timeout=60,
        )

    with subtest("a deleted sentinel is reported missing and not re-created"):
        machine.succeed(f"rm {sentinel}")
        machine.succeed("systemctl start download-root-canary.service")
        machine.succeed(
            f"grep -q 'download_root_canary_present 0' {metrics}"
        )
        # The prime path must NOT have resurrected it: this is the property
        # that keeps a wiping service from resetting the series and hiding
        # the alert.
        machine.fail(f"test -e {sentinel}")

    with subtest("a fresh boot (cleared marker) re-arms the prime"):
        machine.succeed(f"rm -f {marker}")
        machine.succeed("systemctl start download-root-canary.service")
        machine.succeed(f"test -e {sentinel}")
  '';
}
