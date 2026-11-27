# checks/home-assistant.nix
#
# Behaviour test for Home Assistant as cg.service.home-assistant ships it.
#
# Each claim this tests is one the module's header makes and that would only
# otherwise show up on the host, after the nightly switch:
#
# - Requests arriving through Caddy carry X-Forwarded-For, which Home
#   Assistant answers with 400 unless the proxy is trusted.
# - The core settings stay editable in the UI (any source but "yaml"), so
#   onboarding can set the location. One stray key in configuration.yaml -
#   the upstream module's `time_zone` default, say - flips this.
# - The integrations the module ships load, so adding one in the UI does not
#   fail on a missing dependency.
# - The Prometheus endpoint serves metrics, and the host's Prometheus
#   scrapes it with the token from sops. The token file is installed with
#   the ownership the module declares (stub-secrets' `private`), so a
#   missing `owner` fails here as it would in production; the test writes a
#   real token into it, since one can only be minted at runtime.
# - It listens on loopback only; Caddy is the way in. That comes from the
#   HTTP store the module writes, which Home Assistant must take as its
#   stable config rather than a trial that later reverts.
# - The automation, script and scene editors can save, and what they save is
#   loaded. Without the includes in configuration.yaml the save is refused;
#   without the files it fails to start at all.
# - The Matter integration connects to matterjs-server at its default URL,
#   the server listens on loopback only, and the UDP conntrack timeout its
#   subscriptions depend on is in effect after boot.
{
  name = "home-assistant";

  nodes.machine = {
    imports = [
      ../modules/services/home-assistant.nix
      (import ./stub-secrets.nix {
        secrets."prometheus/ha-token" = "replaced-at-runtime";
        private = [ "prometheus/ha-token" ];
      })
    ];

    networking.hostName = "hass";
    system.stateVersion = "24.11";
    # Matches what production sets, so the test sees the default the module
    # has to suppress.
    time.timeZone = "Australia/Perth";

    # Home Assistant's first start installs nothing (nixpkgs ships the
    # dependencies) but still imports a lot of Python; the default 1 GiB is
    # tight enough to make the test flaky.
    virtualisation.memorySize = 2048;

    cg.service.home-assistant.enable = true;

    services.prometheus = {
      enable = true;
      # As modules/services/monitoring/monitoring.nix sets it on the hosts:
      # the token file does not exist when the config is checked at build.
      checkConfig = "syntax-only";
      globalConfig.scrape_interval = "5s";
    };
  };

  testScript =
    { nodes, ... }:
    let
      port = toString nodes.machine.cg.service.home-assistant.port;
    in
    ''
      import json

      base = "http://127.0.0.1:${port}"
      client = "http://127.0.0.1/"

      machine.wait_for_unit("home-assistant.service")
      machine.wait_for_open_port(${port})
      # The port opens before the HTTP component finishes starting.
      machine.wait_until_succeeds(f"curl -sf {base}/manifest.json", timeout=300)

      with subtest("it listens on loopback only"):
          listeners = machine.succeed("ss -Htln 'sport = :${port}'")
          for line in listeners.splitlines():
              local = line.split()[3]
              assert local.startswith(("127.0.0.1:", "[::1]:")), f"listening on {local}"

      with subtest("the HTTP settings are stable, not a trial"):
          # A YAML `http:` block on a fresh state directory is staged as a
          # pending trial, which reverts to the defaults after five minutes,
          # long after the subtests above and below have passed.
          store = json.loads(machine.succeed("cat /var/lib/hass/.storage/http"))["data"]
          assert store["pending"] is None, f"pending HTTP config: {store['pending']}"
          assert store["stable"]["server_host"] == ["127.0.0.1", "::1"], store["stable"]
          config_yaml = machine.succeed("cat /var/lib/hass/configuration.yaml")
          assert "\nhttp:" not in "\n" + config_yaml, "configuration.yaml has an http: block"

      with subtest("a request forwarded by a loopback proxy is accepted"):
          machine.succeed(f"curl -sf -H 'X-Forwarded-For: 192.0.2.10' {base}/manifest.json")

      with subtest("onboarding can create the owner"):
          auth_code = json.loads(machine.succeed(
              f"curl -sf -X POST {base}/api/onboarding/users "
              "-H 'Content-Type: application/json' "
              f"""-d '{{"client_id": "{client}", "name": "Test", "username": "test", """
              """"password": "test-password", "language": "en"}' """
          ))["auth_code"]
          token = json.loads(machine.succeed(
              f"curl -sf -X POST {base}/auth/token "
              f"-d grant_type=authorization_code -d code={auth_code} -d client_id={client}"
          ))["access_token"]
          auth = f"-H 'Authorization: Bearer {token}'"

      with subtest("core settings are left to the UI"):
          core = json.loads(machine.succeed(f"curl -sf {auth} {base}/api/config"))
          # "default" until onboarding saves them, "storage" after. "yaml" is
          # the one that locks the page.
          assert core["config_source"] != "yaml", "core settings are locked to configuration.yaml"

      with subtest("the prometheus endpoint serves metrics"):
          # A YAML integration, set up in a later bootstrap stage than the
          # HTTP server, so the route 404s for a while after the port opens.
          metrics = machine.wait_until_succeeds(
              f"curl -sf {auth} {base}/api/prometheus", timeout=300
          )
          assert "# TYPE" in metrics, metrics[:500]

      with subtest("prometheus scrapes it with the token from sops"):
          token_file = "/run/stub-secrets/prometheus/ha-token"
          owner = machine.succeed(f"stat -c %U {token_file}").strip()
          assert owner == "prometheus", f"token file owned by {owner}"
          # Overwrite in place, keeping the declared ownership and mode.
          machine.succeed(f"printf %s '{token}' > {token_file}")

          def scraped_up(_):
              result = json.loads(machine.succeed(
                  "curl -sfG http://127.0.0.1:9090/api/v1/query "
                  """--data-urlencode 'query=up{job="home-assistant"}'"""
              ))["data"]["result"]
              return bool(result) and result[0]["value"][1] == "1"

          retry(scraped_up, timeout_seconds=120)

      for kind, item_id, body, entity in [
          ("automation", "test_automation",
           {"alias": "Test automation", "triggers": [{"trigger": "sun", "event": "sunset"}],
            "actions": [{"delay": 1}]},
           "automation.test_automation"),
          ("script", "test_script",
           {"alias": "Test script", "sequence": [{"delay": 1}]},
           "script.test_script"),
          ("scene", "test_scene",
           {"name": "Test scene", "entities": {}},
           "scene.test_scene"),
      ]:
          with subtest(f"the {kind} editor saves and the {kind} loads"):
              machine.succeed(
                  f"curl -sf -X POST {auth} {base}/api/config/{kind}/config/{item_id} "
                  "-H 'Content-Type: application/json' "
                  f"-d '{json.dumps(body)}'"
              )
              # Saving reloads the integration; the entity follows shortly.
              machine.wait_until_succeeds(f"curl -sf {auth} {base}/api/states/{entity}", timeout=60)

      with subtest("matterjs-server listens on loopback only"):
          machine.wait_for_unit("matterjs-server.service")
          machine.wait_for_open_port(5580)
          for line in machine.succeed("ss -Htln 'sport = :5580'").splitlines():
              local = line.split()[3]
              assert local.startswith(("127.0.0.1:", "[::1]:")), f"matterjs-server on {local}"

      with subtest("the UDP conntrack timeout outlasts Matter subscriptions"):
          timeout = machine.succeed("sysctl -n net.netfilter.nf_conntrack_udp_timeout_stream").strip()
          assert timeout == "3600", f"nf_conntrack_udp_timeout_stream is {timeout}"

      with subtest("the matter entry connects to matterjs-server"):
          flow = json.loads(machine.succeed(
              f"curl -sf -X POST {auth} {base}/api/config/config_entries/flow "
              "-H 'Content-Type: application/json' "
              """-d '{"handler": "matter"}' """
          ))
          assert flow["type"] == "form", f"matter: {flow}"
          # The default the post-deploy step tells the user to accept.
          result = json.loads(machine.succeed(
              f"curl -sf -X POST {auth} {base}/api/config/config_entries/flow/{flow['flow_id']} "
              "-H 'Content-Type: application/json' "
              """-d '{"url": "ws://localhost:5580/ws"}' """
          ))
          # The flow only creates the entry after it has reached the server.
          assert result["type"] == "create_entry", f"matter: {result}"
          entry = result["result"]

          def matter_loaded(_):
              entries = json.loads(machine.succeed(
                  f"curl -sf {auth} {base}/api/config/config_entries/entry?domain=matter"
              ))
              state = next(e["state"] for e in entries if e["entry_id"] == entry["entry_id"])
              assert state != "setup_error", f"matter entry: {state}"
              return state == "loaded"

          retry(matter_loaded, timeout_seconds=120)

      with subtest("the google_translate entry loads"):
          # Its config flow does not import the library, so opening one
          # (as the loop below does) passes without it. Only setting the
          # entry up does, as onboarding's entry is set up on every start.
          flow = json.loads(machine.succeed(
              f"curl -sf -X POST {auth} {base}/api/config/config_entries/flow "
              "-H 'Content-Type: application/json' "
              """-d '{"handler": "google_translate"}' """
          ))
          entry = json.loads(machine.succeed(
              f"curl -sf -X POST {auth} {base}/api/config/config_entries/flow/{flow['flow_id']} "
              "-H 'Content-Type: application/json' -d '{}'"
          ))["result"]

          def entry_loaded(_):
              entries = json.loads(machine.succeed(
                  f"curl -sf {auth} {base}/api/config/config_entries/entry?domain=google_translate"
              ))
              state = next(e["state"] for e in entries if e["entry_id"] == entry["entry_id"])
              assert state != "setup_error", f"google_translate entry: {state}"
              return state == "loaded"

          retry(entry_loaded, timeout_seconds=60)

      for handler in [
          "hue", "tradfri", "tplink",
          "cast", "dlna_dmr", "samsungtv", "smartthings", "unifi", "unifi_discovery",
          "apple_tv", "ipp", "thread",
          "adguard", "jellyfin", "ntfy", "qbittorrent", "radarr", "sonarr",
          "adaptive_lighting", "magiqtouch", "opensprinkler",
      ]:
          with subtest(f"the {handler} integration loads"):
              flow = json.loads(machine.succeed(
                  f"curl -sf -X POST {auth} {base}/api/config/config_entries/flow "
                  "-H 'Content-Type: application/json' "
                  f"""-d '{{"handler": "{handler}"}}' """
              ))
              # With no devices on the test network a flow may open on its
              # manual-entry form or abort for want of anything to find. Either
              # means the integration imported, as does creating its entry
              # outright, which Thread does since it has nothing to ask. A
              # missing dependency is an HTTP error, which -f has already
              # failed on.
              assert flow["type"] in ("form", "abort", "create_entry"), f"{handler}: {flow}"
    '';
}
