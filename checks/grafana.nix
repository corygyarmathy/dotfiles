# Grafana starts with its provisioned configuration, serves health, and
# exposes what was provisioned - and keeps doing so across a restart against
# the database it populated on first boot.
#
# This is the test that was missing when Grafana spent an afternoon crash
# looping. monitoring.nix assembles datasource and dashboard provisioning out
# of options, and the admin credentials out of $__file{} secret references,
# none of which anything validates until the Grafana process reads them at
# startup - a build gate cannot see any of it. And rejection is fatal in
# Grafana 13: the datasource uid collision recorded at the provisioning block
# in monitoring.nix exited the process on every start, on the host whose job
# includes serving the fleet overview.
#
# Assertions, in increasing order of what they are worth:
#
#   - the unit comes up and /api/health answers. A process that exits during
#     startup never answers; this alone would have caught the incident.
#   - it stays up: after a settle pass NRestarts must still be zero, because
#     one good poll does not rule out a crash that lands after listening.
#   - the Prometheus datasource exists exactly once and is the default -
#     queried over the admin API using the stubbed credentials, so a settings
#     expansion that silently broke auth fails here too.
#   - every dashboard JSON in modules/services/monitoring/dashboards is
#     indexed under the title it declares and loads by uid with a non-empty
#     panel tree. Expected titles and uids are derived from the files
#     themselves, so adding or renaming a dashboard cannot leave this test
#     green while asserting nothing.
#   - a restart re-runs provisioning against the now-populated database and
#     stays healthy with no duplicate datasource row. The incident struck on
#     re-provisioning against existing state, not first boot; restarting the
#     unit runs that same startup-and-provision path. A full VM reboot would
#     cover the boot unit graph too, but buys it at the price of the test
#     driver's allow_reboot machinery and its console-reconnect flake surface,
#     which no other assertion here needs.
#
# Credentials are plaintext fixtures via ./stub-secrets.nix, which is also
# what keeps the module's own sops.secrets declarations covered: name one of
# them differently in monitoring.nix and the stub stops landing. Not covered:
# sops itself (see ./stub-secrets.nix), Prometheus behind the datasource URL -
# provisioning does not dial it, and the scrape side is ./monitoring.nix's job
# - and the reverse proxy front door, which is ./reverse-proxy.nix's.
{
  name = "grafana";

  nodes.machine =
    { ... }:
    {
      imports = [
        ../modules/services/monitoring/monitoring.nix
        (import ./stub-secrets.nix {
          # secret_key is padded past 32 characters because newer Grafana
          # validates its length at startup, and a fixture short enough to be
          # rejected would fail the test for a reason production cannot have.
          secrets."monitoring/grafana/username" = "admin";
          secrets."monitoring/grafana/password" = "test-admin-password";
          secrets."monitoring/grafana/secret_key" = "test-only-secret-key-0123456789abcdef";
        })
      ];

      cg.service.monitoring = {
        enable = true;
        grafana.enable = true;
      };

      # Grafana plus the exporters monitoring.nix enables unconditionally.
      virtualisation.memorySize = 2048;
    };

  testScript =
    let
      # What provisioning is supposed to produce, read from the same JSON the
      # dashboard provider ships. JSON objects are valid Python literals.
      dashboards = map
        (file:
          let
            d = builtins.fromJSON (builtins.readFile (../modules/services/monitoring/dashboards + "/${file}"));
          in
          {
            title = d.title;
            uid = d.uid;
          })
        (builtins.attrNames (builtins.readDir ../modules/services/monitoring/dashboards));
    in
    ''
      import json
      import time

      def admin_get(path):
          return json.loads(machine.succeed(
              "curl -sf -u admin:test-admin-password http://127.0.0.1:3000/{}".format(path)
          ))

      machine.wait_for_unit("grafana.service")

      with subtest("grafana comes up"):
          # The health endpoint is served by the Grafana process itself, so a
          # crash loop that exits during startup - the shape of the incident -
          # never answers here, no matter how patiently systemd restarts it.
          machine.wait_until_succeeds(
              "curl -sf http://127.0.0.1:3000/api/health", timeout=120
          )

      with subtest("grafana stays up"):
          # One successful poll does not rule out a crash that lands after
          # listening. Settle past the provisioning window, then require both
          # that the unit is still active and that it has never restarted:
          # this VM boots fresh, so any nonzero count means something died.
          time.sleep(20)
          assert machine.succeed("systemctl is-active grafana.service").strip() == "active"
          restarts = int(machine.succeed(
              "systemctl show -p NRestarts --value grafana.service"
          ).strip())
          assert restarts == 0, "grafana restarted {} time(s) since boot".format(restarts)

      with subtest("the Prometheus datasource is provisioned once and defaulted"):
          datasources = admin_get("api/datasources")
          prometheus = [d for d in datasources if d["name"] == "Prometheus"]
          assert len(prometheus) == 1, (
              "expected exactly one Prometheus datasource, got: {}".format(datasources)
          )
          ds = prometheus[0]
          assert ds["type"] == "prometheus", ds
          assert ds["isDefault"], ds

      with subtest("every provisioned dashboard is indexed and loads"):
          expected = ${builtins.toJSON dashboards}

          search = admin_get("api/search?type=dash-db")
          indexed = {d["title"]: d["uid"] for d in search}
          for want in expected:
              assert want["title"] in indexed, (
                  "{} missing from provisioned dashboards: {}".format(
                      want["title"], sorted(indexed)
                  )
              )
          extra = set(indexed) - {want["title"] for want in expected}
          assert not extra, (
              "dashboards indexed that no file declares: {}".format(sorted(extra))
          )

          # The stored model is what rendering actually consumes, and loading
          # by uid proves the row provisioning wrote is the row served back.
          # An empty panel tree would mean the model was truncated somewhere
          # between file and database.
          for want in expected:
              stored = admin_get("api/dashboards/uid/" + want["uid"])
              model = stored["dashboard"]
              assert model["title"] == want["title"], model.get("title")
              assert model["panels"], "{} has no panels".format(want["title"])

      with subtest("re-provisioning against the populated database stays healthy"):
          machine.succeed("systemctl restart grafana.service")
          machine.wait_for_unit("grafana.service")
          machine.wait_until_succeeds(
              "curl -sf http://127.0.0.1:3000/api/health", timeout=120
          )

          datasources = admin_get("api/datasources")
          prometheus = [d for d in datasources if d["name"] == "Prometheus"]
          assert len(prometheus) == 1, (
              "restart left {} Prometheus datasources: {}".format(
                  len(prometheus), datasources
              )
          )
    '';
}
