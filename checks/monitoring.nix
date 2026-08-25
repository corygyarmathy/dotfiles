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
#
# The last two subtests cover the alerting side. Routing, inhibition and the
# ntfy bridge are assembled from options just like the scrape configs are, and
# their failure modes are equally silent: a wrong matcher means an alert that
# never notifies anyone. Synthetic alerts are injected straight into the
# Alertmanager API - bypassing rule evaluation, which the promtool/rule-loading
# checks already cover - and asserted against what lands in ntfy's cache.
#
# This test raises globalTimeout because the warning-severity route carries a
# deliberate 5m group_wait: most warnings clear themselves before they are
# worth reading, and asserting delivery means waiting out that grace period.
{
  name = "monitoring";

  # See header. Default is 600 (checks/lib.nix). Boot, the scrape subtests'
  # worst-case waits and both lanes' grace periods fit in twenty minutes.
  globalTimeout = 1200;

  nodes.machine =
    { lib, ... }:
    {
      imports = [
        ../modules/services/monitoring/monitoring.nix
        ../modules/services/monitoring/deploy-metrics.nix

        # Plaintext stand-ins for the three credentials the alerting path
        # reads: the SMTP token (never exercised - the sandbox has no network,
        # so the archive lane's sends fail and are ignored by these asserts),
        # the ntfy access token, and the shared webhook password.
        (import ./stub-secrets.nix {
          secrets."monitoring/proton_smtp_token" = "test-smtp-token";
          secrets."monitoring/ntfy/alerts-token" = "test-ntfy-token";
          secrets."monitoring/ntfy/webhook-password" = "test-webhook-password";
          templates."monitoring/ntfy/alertmanager-ntfy-auth" = ''
            http:
              basic:
                username: alertmanager
                password: "test-webhook-password"
            ntfy:
              auth:
                token: "test-ntfy-token"
          '';
        })
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

        alertmanager = {
          enable = true;

          email = {
            to = "root@localhost";
            from = "alerts@localhost";
            authUsername = "alerts";
            smarthost = "localhost:2525"; # never reachable; see stub note above
          };

          # Quiet hours depend on the wall clock, which would make warning
          # delivery nondeterministic in CI; the mute timing itself is
          # structural config covered by the amtool check next door.
          quietHours.enable = false;

          ntfy = {
            enable = true;
            # The real deployment publishes through Caddy; in the sandbox the
            # sink runs right here.
            baseUrl = "http://127.0.0.1:2586";
          };
        };
      };

      # The push sink: the upstream module directly rather than cg.service.ntfy,
      # because that wrapper requires the reverse proxy and deny-all auth -
      # neither of which belongs in this test. The upstream module mkDefaults
      # auth-file on, which enables deny-by-default access control against an
      # empty user database - every request would 403. Emptying it switches
      # authentication off entirely, so the assertion stays free of
      # user-database setup.
      services.ntfy-sh = {
        enable = true;
        settings = {
          base-url = "http://localhost:2586";
          listen-http = "127.0.0.1:2586";
          auth-file = lib.mkForce "";
          # The assertion loops poll requests faster than ntfy's default
          # per-visitor allowance refills, and a 429 mid-loop reads as a
          # routing failure. Production instances keep the defaults - they
          # exist for exactly this kind of hammering.
          enable-rate-limiting = false;
        };
      };

      # Prometheus plus three exporters plus Alertmanager plus ntfy.
      virtualisation.memorySize = 2048;
    };

  testScript = ''
    import json
    import shlex
    import time
    from datetime import datetime, timedelta, timezone

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

    with subtest("the staged timestamp tracks the generation, not the last rebuild"):
        # Read off the file rather than out of Prometheus: this is about what
        # the script computes, and putting a scrape in the middle would add a
        # minute of waiting and a race to every assertion below.
        def staged_ts():
            machine.succeed("systemctl start nixos-deploy-metrics.service")
            return int(machine.succeed(
                "awk '/^nixos_deploy_staged_timestamp_seconds/ {print $NF}' "
                "/var/lib/prometheus-node-exporter/nixos_deploy.prom"
            ).strip())

        def profile_mtime():
            return int(machine.succeed("stat -c %Y /nix/var/nix/profiles/system").strip())

        # The VM boots straight from the store, so the profile starts with no
        # generations at all. Seed it with what is running, as a host has.
        running = machine.succeed("readlink -f /run/current-system").strip()
        machine.succeed("nix-env -p /nix/var/nix/profiles/system --set {}".format(running))
        first, first_mtime = staged_ts(), profile_mtime()

        # Whole-second mtimes, so a timestamp that moves has to move visibly.
        machine.succeed("sleep 2")

        # What a nightly rebuild does on a host nothing has changed: the same
        # store path set again. nix keeps the generation it already has and
        # re-points the profile symlink at it anyway.
        machine.succeed("nix-env -p /nix/var/nix/profiles/system --set {}".format(running))
        second, second_mtime = staged_ts(), profile_mtime()

        # The control. Without it the assertion below would also pass on a day
        # when nix stopped re-pointing an unchanged profile - green because the
        # condition under test had gone away, which is the failure a regression
        # test is least able to survive.
        assert second_mtime > first_mtime, (
            "the profile symlink was not re-pointed ({} == {}), so this no longer "
            "reproduces what a no-change rebuild does and proves nothing"
            .format(first_mtime, second_mtime)
        )

        # The claim: re-staging the generation that is already staged is not a
        # staging event. Reading the profile symlink's own mtime said it was,
        # which reset NixosRebootPending's 26h window nightly and fired
        # NixosVerifyStale against a generation verified two days earlier.
        assert second == first, (
            "staged timestamp moved ({} -> {}) for a generation that was already "
            "staged; it is reporting rebuilds rather than generations"
            .format(first, second)
        )

    with subtest("alertmanager routes, inhibits and pushes"):
        machine.wait_for_unit("alertmanager.service")
        machine.wait_for_unit("alertmanager-ntfy.service")
        machine.wait_for_unit("ntfy-sh.service")
        machine.wait_until_succeeds("curl -sf http://localhost:9093/-/ready", timeout=60)
        machine.wait_until_succeeds("curl -sf http://localhost:2586/v1/health", timeout=60)

        def post_alerts(alerts):
            body = json.dumps(
                [
                    {
                        "labels": dict(a["labels"]),
                        "annotations": {
                            "summary": "{} summary".format(a["labels"]["alertname"]),
                            "description": "{} description".format(a["labels"]["alertname"]),
                        },
                        "startsAt": datetime.now(timezone.utc).isoformat(),
                        "endsAt": (datetime.now(timezone.utc) + timedelta(hours=4)).isoformat(),
                    }
                    for a in alerts
                ]
            )
            machine.succeed(
                "curl -sf -XPOST -H 'Content-Type: application/json' "
                "http://localhost:9093/api/v2/alerts -d {}".format(shlex.quote(body))
            )

        _poll_failures = [0]

        def messages():
            # Public subscribe API: NDJSON stream that ends immediately when
            # poll=1. Only message events carry notifications. Paced slower
            # than one request per default replenish interval so the loop
            # stays inside ntfy's visitor allowance no matter what.
            time.sleep(6)
            code = machine.succeed(
                "curl -s -o /tmp/poll-body -w '%{http_code}' "
                "'http://localhost:2586/alerts/json?poll=1'"
            ).strip()
            if not code.startswith("2"):
                _poll_failures[0] += 1
                if _poll_failures[0] <= 2:
                    machine.log(
                        "POLL-ERROR status={} body={}".format(
                            code,
                            machine.succeed("cat /tmp/poll-body || true")[:300].replace("\n", " | "),
                        )
                    )
                return []
            body = machine.succeed("cat /tmp/poll-body")
            return [
                json.loads(line)
                for line in body.splitlines()
                if line.strip() and json.loads(line).get("event") == "message"
            ]

        def titles(msgs):
            return {m.get("title", "") for m in msgs}

        # Two hosts' worth of synthetic alerts:
        #
        #  deadhost - TargetDown plus HighMemoryUsage for an instance nothing
        #             can reach. The inhibition rule must let the root cause
        #             through and swallow the symptom; if HighMemoryUsage ever
        #             shows up below, inhibition is broken in exactly the way
        #             that turns one outage into a full inbox.
        #  vm       - TestCritical and TestWarning exercise the severity
        #             lanes end to end, including the priority each arrives
        #             with. TestInfo has no matching route and must stay off
        #             push entirely (email only).
        post_alerts(
            [
                {"labels": {"alertname": "TargetDown", "severity": "critical", "instance": "deadhost:9100", "job": "node"}},
                {"labels": {"alertname": "HighMemoryUsage", "severity": "warning", "instance": "deadhost:9100"}},
                {"labels": {"alertname": "TestCritical", "severity": "critical", "instance": "vm:9100"}},
                {"labels": {"alertname": "TestWarning", "severity": "warning", "instance": "vm:9100"}},
                {"labels": {"alertname": "TestInfo", "severity": "info", "instance": "vm:9100"}},
            ]
        )

        # Critical lane: group_wait is 30s, so this also proves the bridge and
        # ntfy are actually wired together.
        def critical_arrived(_):
            return any("TargetDown" in t or "TestCritical" in t for t in titles(messages()))

        retry(critical_arrived, timeout=timedelta(seconds=120))

        # Warning lane: its group_wait is deliberately 5m. The retry window
        # starts after the critical lane's assertions, so it only needs to
        # cover the remaining grace period plus polling slack - but keep a
        # full 7m so a slow run cannot flake against the deadline.
        def warning_arrived(_):
            return any("TestWarning" in t for t in titles(messages()))

        retry(warning_arrived, timeout=timedelta(seconds=420))

        msgs = messages()
        crit = [m for m in msgs if "TestCritical" in m.get("title", "")]
        warn = [m for m in msgs if "TestWarning" in m.get("title", "")]
        down = [m for m in msgs if "TargetDown" in m.get("title", "")]
        inhibited = [m for m in msgs if "HighMemoryUsage" in m.get("title", "")]
        info = [m for m in msgs if "TestInfo" in m.get("title", "")]

        assert crit and down and warn, "expected all three routed lanes to arrive: {}".format(sorted(titles(msgs)))
        assert not inhibited, "inhibition failed: HighMemoryUsage notified despite TargetDown firing"
        assert not info, "info-severity alert reached push; it should be email-only"

        # ntfy priorities: 5 urgent (buzz), 2 low (silent), 3 default.
        assert crit[0]["priority"] == 5, "critical did not arrive urgent: {}".format(crit[0])
        assert warn[0]["priority"] == 2, "warning did not arrive silent: {}".format(warn[0])
        assert down[0]["priority"] == 5, "root-cause alert did not arrive urgent: {}".format(down[0])

        # Resolved notifications follow their alert's route with
        # send_resolved enabled on the webhook, so resolutions land on push as
        # ordinary-priority all-clears - asserted structurally by amtool rather
        # than here, because Alertmanager batches resolutions on group_interval
        # and waiting that out does not fit this harness.
  '';
}
