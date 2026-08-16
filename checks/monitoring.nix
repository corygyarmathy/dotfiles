# Prometheus starts, loads its rules, and scrapes a target that is really
# reporting - including the deployment pipeline's own telemetry.
#
# The `alert-rules` check next door runs `promtool check rules` over
# alert-rules.yml, which proves that one file is syntactically valid in
# isolation. It says nothing about the config Prometheus is actually handed:
# scrape jobs, relabelling, the alertmanager block and the rule file are
# assembled by monitoring.nix from options, and a mistake there surfaces only
# when the server refuses to start on the host - i.e. after activation, on the
# machine that is meant to be watching everything else.
#
# The last subtest is the one worth having. ADR 0001's deployment metrics
# reach Prometheus through a chain of four independent pieces - deploy-metrics
# writes a .prom file, monitoring.nix has to enable node_exporter's textfile
# collector, node_exporter has to be pointed at the right directory, and
# Prometheus has to scrape it - and a break anywhere along it is silent. The
# alerts simply never fire, which is indistinguishable from nothing being
# wrong. deploy-metrics.nix already carries a comment about having had to
# override a `mkDefault` that left the collector off on homelab01, so this is
# not a hypothetical.
#
# `cloudflaredTarget` is set here rather than left at its default because the
# default is `null` and monitoring.nix drops it into a static_configs target
# list unconditionally. Both hosts set it, so the null path is unreachable in
# production - it is called out so that this test is not blamed for it later.
{
  name = "monitoring";

  nodes.machine = {
    imports = [
      ../modules/services/monitoring/monitoring.nix
      ../modules/services/monitoring/deploy-metrics.nix
    ];

    cg.service.monitoring = {
      enable = true;
      prometheus.enable = true;

      # Scrape this machine's own node_exporter. A real target, so `up` means
      # the scrape loop genuinely completed rather than that the config parsed.
      scrapeTargets = [ "localhost:9100" ];
      cloudflaredTarget = "localhost:20241";

      # On a host this defaults on wherever system.autoUpgrade is enabled,
      # which no test VM is. Forced on because it is half of what this test is
      # here to cover.
      deploy.enable = true;

      httpProbes = [
        {
          name = "self";
          url = "http://localhost:9090/-/healthy";
        }
      ];
    };

    # Prometheus plus three exporters; the default leaves this thrashing.
    virtualisation.memorySize = 2048;
  };

  testScript = ''
    import json
    from datetime import timedelta

    def query(expr):
        out = machine.succeed(
            "curl -sf --get --data-urlencode 'query={}' "
            "http://localhost:9090/api/v1/query".format(expr)
        )
        return json.loads(out)["data"]["result"]

    machine.wait_for_unit("prometheus.service")
    machine.wait_for_open_port(9090)
    machine.wait_until_succeeds("curl -sf http://localhost:9090/-/ready", timeout=120)

    with subtest("the rule file is loaded by the server, not merely valid on disk"):
        rules = json.loads(machine.succeed("curl -sf http://localhost:9090/api/v1/rules"))
        assert rules["status"] == "success", rules
        groups = rules["data"]["groups"]
        assert groups, "Prometheus started with no rule groups loaded"

        names = {r["name"] for g in groups for r in g["rules"]}
        # One representative from each family the deployment pipeline depends
        # on. If alert-rules.yml is reorganised these names may legitimately
        # change - but they should change deliberately, not silently.
        for expected in ["NixosDeployFailed", "NixosDeployStale", "NixosVerifyFailed"]:
            assert expected in names, f"{expected} missing from loaded rules: {sorted(names)}"

    with subtest("a target is actually scraped"):
        machine.wait_for_unit("prometheus-node-exporter.service")
        machine.wait_for_open_port(9100)

        # scrape_interval is 1m and Prometheus jitters each target's first
        # scrape across that window, so this can genuinely take a minute.
        def node_up(_):
            result = query('up{job="node"}')
            return bool(result) and result[0]["value"][1] == "1"

        retry(node_up, timeout=timedelta(seconds=180))

    with subtest("deployment metrics reach Prometheus"):
        # NOT wait_for_unit: nixos-deploy-metrics is a Type=oneshot without
        # RemainAfterExit, so it reads `inactive` the moment it succeeds and
        # waiting for it to be active waits forever. Starting it explicitly is
        # also the deterministic choice - it already ran at multi-user.target,
        # and this removes the race with node_exporter's first read.
        #
        # (The same shape is the trap item 3 documents for criticalUnits:
        # `is-active` is only meaningful for a oneshot that sets
        # RemainAfterExit. This unit is not probed there, but it is the same
        # mistake waiting to be made.)
        machine.succeed("systemctl start nixos-deploy-metrics.service")

        # First that the file is written where the collector is looking, so a
        # failure here points at deploy-metrics rather than at the scrape.
        machine.succeed("test -s /var/lib/prometheus-node-exporter/nixos_deploy.prom")

        # Then that node_exporter's textfile collector is switched on and
        # pointed at that directory - the wiring deploy-metrics.nix has to
        # override a mkDefault to get.
        #
        # Written to a file rather than piped into grep: the test driver runs
        # commands under `pipefail`, and `grep -q` exits at the first match,
        # which hands curl an EPIPE and fails the whole pipeline for a match
        # that was actually found. The symptom is a passing condition that
        # times out, so it is worth not writing it the obvious way.
        machine.wait_until_succeeds(
            "curl -sf -o /tmp/node-metrics http://localhost:9100/metrics "
            "&& grep -q nixos_deploy_revision_info /tmp/node-metrics",
            timeout=60,
        )

        # And finally that it survives the scrape, which is the only step that
        # proves the whole ADR 0001 telemetry chain is connected.
        def revision_exported(_):
            return bool(query("nixos_deploy_revision_info"))

        retry(revision_exported, timeout=timedelta(seconds=180))
  '';
}
