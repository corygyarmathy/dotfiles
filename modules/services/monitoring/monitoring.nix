# Minimal monitoring
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.cg.service.monitoring;
  fleet = config.cg.fleet;

  # The fleet's always-on machines: what gets scraped. Sorted, because
  # `attrNames` is, which keeps the generated scrape config stable.
  servers = lib.attrNames (lib.filterAttrs (_: host: host.kind == "server") fleet.hosts);

  # Timezone both wall-clock mute intervals are evaluated in. Quiet hours and
  # the maintenance window are statements about the hosts' local time, not
  # UTC, so they share the host timezone (Australia/Perth for this fleet).
  muteLocation =
    if cfg.alertmanager.quietHours.timeZone != null then
      cfg.alertmanager.quietHours.timeZone
    else
      "UTC";

  # ZFS health metrics script for textfile collector
  # Outputs Prometheus metrics for ZFS pool health
  zfsHealthScript = pkgs.writeShellScript "zfs-health-exporter" ''
    set -euo pipefail

    OUTPUT_DIR="/var/lib/prometheus-node-exporter"
    OUTPUT_FILE="$OUTPUT_DIR/zfs.prom"
    TEMP_FILE="$OUTPUT_DIR/zfs.prom.tmp"

    # Ensure output directory exists
    mkdir -p "$OUTPUT_DIR"

    # Start fresh
    > "$TEMP_FILE"

    # Check if zpool command exists
    if ! command -v zpool &> /dev/null; then
      echo "# No ZFS pools found" >> "$TEMP_FILE"
      mv "$TEMP_FILE" "$OUTPUT_FILE"
      exit 0
    fi

    # Get list of pools
    pools=$(${pkgs.zfs}/bin/zpool list -H -o name 2>/dev/null || true)

    if [ -z "$pools" ]; then
      echo "# No ZFS pools found" >> "$TEMP_FILE"
      mv "$TEMP_FILE" "$OUTPUT_FILE"
      exit 0
    fi

    # Pool health metric (1 = healthy, 0 = unhealthy)
    echo "# HELP zfs_pool_health ZFS pool health status (1 = ONLINE, 0 = degraded/faulted)" >> "$TEMP_FILE"
    echo "# TYPE zfs_pool_health gauge" >> "$TEMP_FILE"

    # Pool state metric (for detailed state info)
    echo "# HELP zfs_pool_state ZFS pool state (label contains actual state)" >> "$TEMP_FILE"
    echo "# TYPE zfs_pool_state gauge" >> "$TEMP_FILE"

    # Error counters
    echo "# HELP zfs_pool_read_errors Total read errors on pool" >> "$TEMP_FILE"
    echo "# TYPE zfs_pool_read_errors gauge" >> "$TEMP_FILE"
    echo "# HELP zfs_pool_write_errors Total write errors on pool" >> "$TEMP_FILE"
    echo "# TYPE zfs_pool_write_errors gauge" >> "$TEMP_FILE"
    echo "# HELP zfs_pool_checksum_errors Total checksum errors on pool" >> "$TEMP_FILE"
    echo "# TYPE zfs_pool_checksum_errors gauge" >> "$TEMP_FILE"

    # Scrub metrics
    echo "# HELP zfs_pool_scrub_errors Errors found during last scrub" >> "$TEMP_FILE"
    echo "# TYPE zfs_pool_scrub_errors gauge" >> "$TEMP_FILE"
    echo "# HELP zfs_pool_scrub_age_seconds Seconds since last completed scrub" >> "$TEMP_FILE"
    echo "# TYPE zfs_pool_scrub_age_seconds gauge" >> "$TEMP_FILE"

    for pool in $pools; do
      # Get pool health state
      state=$(${pkgs.zfs}/bin/zpool list -H -o health "$pool" 2>/dev/null || echo "UNKNOWN")
      
      # Convert state to binary health metric
      if [ "$state" = "ONLINE" ]; then
        health=1
      else
        health=0
      fi
      
      echo "zfs_pool_health{pool=\"$pool\",state=\"$state\"} $health" >> "$TEMP_FILE"
      
      # State breakdown (useful for alerting on specific states)
      for s in ONLINE DEGRADED FAULTED OFFLINE REMOVED UNAVAIL SUSPENDED; do
        if [ "$state" = "$s" ]; then
          echo "zfs_pool_state{pool=\"$pool\",state=\"$s\"} 1" >> "$TEMP_FILE"
        else
          echo "zfs_pool_state{pool=\"$pool\",state=\"$s\"} 0" >> "$TEMP_FILE"
        fi
      done
      
      # Get error counts from zpool status
      # Parse the pool line for read/write/checksum errors
      status_output=$(${pkgs.zfs}/bin/zpool status -p "$pool" 2>/dev/null || true)
      
      # Extract errors from the pool line (the line right after NAME STATE READ WRITE CKSUM)
      # Using awk to find the pool name line and extract error counts
      read_errors=$(echo "$status_output" | awk -v pool="$pool" '$1 == pool {print $3}' | head -1)
      write_errors=$(echo "$status_output" | awk -v pool="$pool" '$1 == pool {print $4}' | head -1)
      cksum_errors=$(echo "$status_output" | awk -v pool="$pool" '$1 == pool {print $5}' | head -1)
      
      # Default to 0 if parsing failed
      read_errors=''${read_errors:-0}
      write_errors=''${write_errors:-0}
      cksum_errors=''${cksum_errors:-0}
      
      echo "zfs_pool_read_errors{pool=\"$pool\"} $read_errors" >> "$TEMP_FILE"
      echo "zfs_pool_write_errors{pool=\"$pool\"} $write_errors" >> "$TEMP_FILE"
      echo "zfs_pool_checksum_errors{pool=\"$pool\"} $cksum_errors" >> "$TEMP_FILE"
      
      # Scrub information
      # Look for "scrub repaired X in HH:MM:SS with Y errors on <date>"
      scrub_line=$(echo "$status_output" | grep -E "scrub repaired|scrub in progress" || true)
      
      if echo "$scrub_line" | grep -q "scrub repaired"; then
        # Extract errors from completed scrub
        scrub_errors=$(echo "$scrub_line" | grep -oP 'with \K[0-9]+(?= errors)' || echo "0")
        echo "zfs_pool_scrub_errors{pool=\"$pool\"} $scrub_errors" >> "$TEMP_FILE"
        
        # Extract scrub completion date and calculate age
        # Format: "scrub repaired 0B in 01:23:45 with 0 errors on Sun Jan  5 02:00:01 2025"
        scrub_date=$(echo "$scrub_line" | grep -oP 'on \K.*$' || true)
        if [ -n "$scrub_date" ]; then
          scrub_timestamp=$(date -d "$scrub_date" +%s 2>/dev/null || echo "0")
          if [ "$scrub_timestamp" != "0" ]; then
            now=$(date +%s)
            scrub_age=$((now - scrub_timestamp))
            echo "zfs_pool_scrub_age_seconds{pool=\"$pool\"} $scrub_age" >> "$TEMP_FILE"
          fi
        fi
      elif echo "$scrub_line" | grep -q "scrub in progress"; then
        # Scrub is running, report 0 errors (will update when done)
        echo "zfs_pool_scrub_errors{pool=\"$pool\"} 0" >> "$TEMP_FILE"
      fi
    done

    # Atomic move to prevent partial reads
    mv "$TEMP_FILE" "$OUTPUT_FILE"
  '';

  gluetunHealthScript = pkgs.writeShellScript "gluetun-health-exporter" ''
    set -euo pipefail

    OUTPUT_DIR="/var/lib/prometheus-node-exporter"
    OUTPUT_FILE="$OUTPUT_DIR/gluetun.prom"
    TEMP_FILE="$OUTPUT_DIR/gluetun.prom.tmp"

    mkdir -p "$OUTPUT_DIR"
    > "$TEMP_FILE"

    RAW_KEY=$(cat "/run/secrets/media-stack/vpn/http-api-key")
    API_KEY=$(echo "$RAW_KEY" | sed 's/^HTTP_CONTROL_SERVER_API_KEY=//')
    PORT=${toString cfg.vpn.gluetunPort}

    echo "# HELP gluetun_vpn_connected Whether Gluetun has an active VPN connection (1=yes, 0=no)" >> "$TEMP_FILE"
    echo "# TYPE gluetun_vpn_connected gauge" >> "$TEMP_FILE"
    echo "# HELP gluetun_port_forwarded Currently forwarded port (0 if none)" >> "$TEMP_FILE"
    echo "# TYPE gluetun_port_forwarded gauge" >> "$TEMP_FILE"

    STATUS=$(${pkgs.curl}/bin/curl -sf --max-time 5 \
      -H "X-API-Key: $API_KEY" \
      "http://localhost:$PORT/v1/vpn/status" 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r '.status // empty' 2>/dev/null || echo "")

    if [ "$STATUS" = "running" ]; then
      echo "gluetun_vpn_connected 1" >> "$TEMP_FILE"
    else
      echo "gluetun_vpn_connected 0" >> "$TEMP_FILE"
    fi

    FORWARDED=$(${pkgs.curl}/bin/curl -sf --max-time 5 \
      -H "X-API-Key: $API_KEY" \
      "http://localhost:$PORT/v1/portforward" 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r '.port // 0' 2>/dev/null || echo "0")

    echo "gluetun_port_forwarded $FORWARDED" >> "$TEMP_FILE"

    mv "$TEMP_FILE" "$OUTPUT_FILE"
  '';
in
{
  # Reads config.cg.fleet and config.cg.publish, and publishes its own three
  # web UIs into the latter - see modules/nixos/fleet.nix and
  # modules/nixos/publish.nix.
  imports = [
    ../../nixos/fleet.nix
    ../../nixos/publish.nix
  ];

  options.cg.service.monitoring = {
    enable = lib.mkEnableOption "Monitoring stack";

    prometheus.enable = lib.mkEnableOption "Prometheus server";
    grafana.enable = lib.mkEnableOption "Grafana dashboard";

    alertmanager = {
      enable = lib.mkEnableOption "Alertmanager";
      clusterPeers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "homelab01:9094" ];
        description = "Alertmanager cluster peers for HA deduplication";
      };

      # Email alerting configuration
      email = {
        to = lib.mkOption {
          type = lib.types.str;
          example = "admin@example.com";
          description = "Email address to send alerts to";
        };

        from = lib.mkOption {
          type = lib.types.str;
          example = "alerts@example.com";
          description = "Email address to send alerts from";
        };

        smarthost = lib.mkOption {
          type = lib.types.str;
          default = "smtp.protonmail.ch:587";
          description = "SMTP server and port";
        };

        authUsername = lib.mkOption {
          type = lib.types.str;
          description = "SMTP authentication username";
        };
      };

      # Push notifications through a self-hosted ntfy server, via the
      # alertmanager-ntfy bridge running next to Alertmanager on this host.
      # Critical alerts buzz the phone; warnings arrive silently; everything
      # keeps flowing to email as the archive lane regardless of severity.
      # See the receiver/route/inhibition design in the config section below.
      ntfy = {
        enable = lib.mkEnableOption "ntfy push routing for Alertmanager";

        # Loopback port the local bridge listens on, and the one port
        # Alertmanager delivers to. Both sides are read from here, so the
        # number matters only in that nothing else on the host may hold it.
        #
        # It is 8015 rather than the 8000 this defaulted to, because 8000 is
        # taken by convention wherever the media stack runs: gluetun's HTTP
        # control server is published there (qbittorrent.nix), and gluetun
        # coexists with this bridge precisely on storage hosts. The bridge
        # landed on homelab02 against that, lost the bind race on every
        # start, crash-looped all night, and the switch that activated it
        # reported failed units. That was repaired by having homelab02 name
        # a different port - which left the collision in the default, one
        # host away from happening again. A default that does not collide
        # with anything this fleet runs costs nothing and needs no host to
        # remember.
        port = lib.mkOption {
          type = lib.types.port;
          default = 8015;
          description = ''
            Loopback port for the local alertmanager-ntfy bridge. Anything
            loopback and free will do; there is nothing to match on either
            side. Avoid 8000, which gluetun's control server is published on
            wherever the media stack runs.
          '';
        };

        baseUrl = lib.mkOption {
          type = lib.types.str;
          default = "https://ntfy.${fleet.domain}";
          defaultText = lib.literalExpression ''"https://ntfy.''${config.cg.fleet.domain}"'';
          description = "Base URL of the ntfy server the bridge publishes to";
        };

        topic = lib.mkOption {
          type = lib.types.str;
          default = "alerts";
          description = "ntfy topic alerts are published to";
        };

        tokenSecret = lib.mkOption {
          type = lib.types.str;
          default = "monitoring/ntfy/alerts-token";
          description = "Sops secret holding the ntfy access token used by the bridge";
        };

        webhookPasswordSecret = lib.mkOption {
          type = lib.types.str;
          default = "monitoring/ntfy/webhook-password";
          description = ''
            Sops secret holding the basic-auth password shared by every
            Alertmanager in the fleet and the bridges they deliver to. Use
            URL-safe characters (letters, digits, - _ ~ .); it is embedded
            in a YAML file verbatim.
          '';
        };

        # Grace period before a warning-severity alert first notifies.
        # Warnings wait longer than criticals because most clear themselves
        # before they are worth reading. Exposed as an option so the VM test
        # can shorten it: the test proves a warning routes to push with the
        # right priority, not that it waits the production five minutes, and
        # the production value is still pinned structurally by the amtool
        # check (checks/default.nix).
        warningGroupWait = lib.mkOption {
          type = lib.types.str;
          default = "5m";
          description = "Grace period before a warning-severity alert first notifies";
        };
      };

      # Warning-severity push notifications are suppressed between these
      # times so a failing timer at 04:15 is read at breakfast rather than
      # buzzing then. Criticals ignore quiet hours by design. Applies to the
      # ntfy lane only; email is never muted.
      quietHours = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Mute warning-severity push notifications outside waking hours";
        };
        start = lib.mkOption {
          type = lib.types.strMatching "[0-9]{2}:[0-9]{2}";
          default = "22:00";
          description = "Start of the quiet window (local time)";
        };
        end = lib.mkOption {
          type = lib.types.strMatching "[0-9]{2}:[0-9]{2}";
          default = "07:00";
          description = "End of the quiet window (local time)";
        };
        timeZone = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          # time.timeZone is null when unset; the consumer falls back to UTC,
          # which only ever matters for test/standalone evaluations - both
          # hosts set it explicitly.
          default = config.time.timeZone;
          defaultText = lib.literalExpression "config.time.timeZone";
          description = "IANA timezone the quiet window is evaluated in";
        };
      };

    };

    # ZFS monitoring
    zfs = {
      enable = lib.mkEnableOption "ZFS pool health monitoring";
    };

    # Targets for Prometheus to scrape
    #
    # Both default to every machine the fleet calls a `server` - the ones with
    # a reserved address, expected to be up - at the port this module gives
    # its own exporters. Neither the host list nor the port is written down
    # twice: the hosts came from `cg.fleet` and the port from the exporter
    # that answers on it, so moving either moves the scrape with it.
    scrapeTargets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = map (host: "${host}:${toString config.services.prometheus.exporters.node.port}") servers;
      defaultText = lib.literalExpression "every `server` in `config.cg.fleet`, at the node_exporter port";
      description = "List of node_exporter targets to scrape";
    };

    smartctlTargets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = map (
        host: "${host}:${toString config.services.prometheus.exporters.smartctl.port}"
      ) servers;
      defaultText = lib.literalExpression "every `server` in `config.cg.fleet`, at the smartctl_exporter port";
      description = "List of smartctl_exporter targets to scrape";
    };

    # HTTP endpoints to probe
    #
    # Derived from `cg.publish`, and that is the point: the two hosts used to
    # hand-maintain overlapping lists, and by the time this was written seven
    # proxied hostnames were probed from nowhere - two of them published to
    # the internet. A service that is published and not probed is no longer
    # expressible, because nothing writes this list any more.
    #
    # Each host probes what its own Caddy serves. `cg.publish` is per-host, so
    # a host cannot see what its peer publishes, and the union of the two
    # covers the fleet exactly once. The dual coverage the hand-written lists
    # happened to give is gone with them; a host that is down takes its own
    # probes with it and is reported by the node and target-down alerts
    # instead.
    #
    # The value is the option's *default* rather than a fixed computation, for
    # the reason modules/nixos/fleet.nix gives about `cg.fleet`: checks/
    # instantiates this module directly and needs to point a probe at a target
    # that exists inside a sandboxed VM. No host sets it.
    httpProbes = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Name of the service being probed";
            };
            url = lib.mkOption {
              type = lib.types.str;
              description = "URL to probe";
            };
          };
        }
      );
      default = lib.mapAttrsToList (name: svc: {
        inherit name;
        url = "https://${svc.subdomain}.${fleet.domain}${svc.probePath}";
      }) (lib.filterAttrs (_: svc: svc.probe) config.cg.publish);
      defaultText = lib.literalExpression ''
        every `config.cg.publish` entry with `probe = true`, as
        `https://''${subdomain}.''${config.cg.fleet.domain}''${probePath}`
      '';
      description = "HTTP endpoints to probe with blackbox_exporter";
    };

    # Reachability from outside the affected host (item 9 of
    # docs/plans/deployment-hardening.md).
    #
    # `httpProbes` covers what this host itself serves, and blackbox runs on
    # the same host - so a change that cuts a host off from the network leaves
    # every probe green, because locally everything is fine. That is the one
    # gap whose recovery is physical, and nothing on the host can notice it.
    #
    # This is the other host's view: each server probes the *peer's* dedicated
    # host-alive beacon (a published, dependency-free 200-responder, see
    # modules/services/host-alive.nix) and the peer's own Prometheus - a
    # different machine, presumed still up - evaluates and pages. Empty by
    # default so a host that wants no remote reachability monitoring declares
    # nothing; both fleet servers set it.
    #
    # The probe URL is the beacon's public hostname, but the path the probe
    # takes to reach it is *not* part of the guarantee. The fleet resolver
    # answers `alive-*` with the LAN address (the wildcard in
    # adguard-home.nix), so in practice the probe crosses the LAN to the peer's
    # beacon through Caddy; if the probing host resolves publicly instead, the
    # same URL rides the tunnel to Cloudflare's edge. Either way the *observer*
    # is a different machine, which is the property item 9 needs. The path only
    # changes which failure modes are visible, and the repo does not control
    # it (the resolver a host uses is handed out by the router's DHCP, outside
    # this repository). True public-internet reachability - guaranteeing the
    # tunnel path - is deferred as a future item in the hardening plan.
    #
    # Deliberately just hostnames, per the plan's "not a second monitoring
    # stack": the probes reuse the existing blackbox exporter, and the alert
    # they feed reuses the rule/runbook machinery. Nothing here needs a new
    # service, a token, or a store path.
    remoteProbes = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Name of the away host being probed";
            };
            url = lib.mkOption {
              type = lib.types.str;
              description = "Public URL of the away host's host-alive beacon";
            };
          };
        }
      );
      default = [ ];
      example = [
        {
          name = "homelab02";
          url = "https://alive-homelab02.gyarmathy.co";
        }
      ];
      description = ''
        The peer's host-alive beacon (see modules/services/host-alive.nix),
        probed by this host so a machine cut off from its network is noticed
        by a different machine that is still up. Each entry is a name and the
        beacon's public URL - not one of the peer's real services, so the
        watch does not decay when a service is moved or disabled. The URL is
        public, but the path the probe takes to it is a function of fleet DNS
        resolution (LAN via the wildcard, or public via the tunnel) and is not
        part of the guarantee; what is guaranteed is that the observer is
        another host, so it can still page when the affected one cannot.
      '';
    };

    cloudflaredTarget = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "homelab01:20241";
      description = "Cloudflared metrics endpoint to scrape (null to disable)";
    };

    vpn = {
      enable = lib.mkEnableOption "VPN (Gluetun) health monitoring";

      gluetunApiKeySecret = lib.mkOption {
        type = lib.types.str;
        description = "Sops secret path for Gluetun HTTP control server API key";
        example = "media-stack/vpn/http-api-key";
        default = "media-stack/vpn/http-api-key";
      };

      gluetunPort = lib.mkOption {
        type = lib.types.port;
        default = 8000;
        description = "Gluetun HTTP control server port";
      };
    };

    textfileCollector = {
      enable = lib.mkEnableOption "textfile collector for node_exporter";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # ============================================================
      # Always: exporters (node, smartctl, firewall)
      # ============================================================
      {
        cg.service.monitoring.textfileCollector.enable = lib.mkDefault (cfg.zfs.enable || cfg.vpn.enable);

        services.prometheus.exporters = {
          node = {
            enable = true;
            enabledCollectors = [
              "systemd"
              "processes"
            ]
            ++ lib.optionals cfg.textfileCollector.enable [
              "textfile"
            ];
            listenAddress = "0.0.0.0";
            port = 9100;
            extraFlags = lib.optionals cfg.textfileCollector.enable [
              "--collector.textfile.directory=/var/lib/prometheus-node-exporter"
            ];
          };

          smartctl = {
            enable = true;
            listenAddress = "0.0.0.0";
            port = 9633;
          };
        };

        networking.firewall.allowedTCPPorts = [
          9100
          9633
        ];
      }

      # ============================================================
      # ZFS monitoring
      # ============================================================
      (lib.mkIf cfg.zfs.enable {
        # Systemd service to periodically export ZFS metrics
        systemd.services.zfs-health-exporter = {
          description = "Export ZFS pool health metrics for Prometheus";
          after = [ "zfs.target" ];
          wants = [ "zfs.target" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = zfsHealthScript;
            User = "root"; # Need root to run zpool commands
          };
        };

        # Timer to run the exporter every minute
        systemd.timers.zfs-health-exporter = {
          description = "Timer for ZFS health metrics exporter";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "1min";
            OnUnitActiveSec = "1min";
            Unit = "zfs-health-exporter.service";
          };
        };

        # Ensure the textfile directory exists
        systemd.tmpfiles.rules = [
          "d /var/lib/prometheus-node-exporter 0755 root root -"
        ];
      })

      # ============================================================
      # Prometheus server + blackbox exporter
      # ============================================================
      (lib.mkIf cfg.prometheus.enable {
        # A hostname for the graph view, but only where Grafana is. Every
        # host in the fleet runs a Prometheus, and a subdomain names one
        # machine - so publishing from each of them would put the same
        # hostname on two proxies, where DNS decides which one answers and
        # the other holds a certificate for a name it never serves. Grafana
        # runs on one host, and it is the thing that links here, so its
        # presence is the sensible place to hang the name. Reach the others
        # at `<host>:9090` over ssh.
        #
        # The port comes from the upstream option rather than a literal, which
        # is the whole point of the registry: nothing here can drift from what
        # Prometheus is actually listening on.
        cg.publish = lib.mkIf cfg.grafana.enable {
          prometheus.port = config.services.prometheus.port;
        };

        services.prometheus.exporters.blackbox = {
          enable = true;
          configFile = pkgs.writeText "blackbox.yml" ''
            modules:
              http_2xx:
                prober: http
                timeout: 5s
                http:
                  valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
                  valid_status_codes: [200]
                  method: GET
                  follow_redirects: true
                  preferred_ip_protocol: "ip4"
          '';
        };

        services.prometheus = {
          enable = true;
          # Up from the 15d default, because the questions this stack is asked
          # are monthly ones: whether health-gated activation ever wanted to
          # roll back, whether a threshold was right, how often the lock update
          # produced an empty diff. A 30d query against 15d of data silently
          # returns 15d and looks better-evidenced than it is.
          #
          # Cheap here - a handful of targets at a 1m interval, against 160GB
          # free on the host holding the pool.
          retentionTime = "30d";
          globalConfig = {
            scrape_interval = "1m";
            scrape_timeout = "30s"; # was defaulting to 10s
          };
          scrapeConfigs = [
            {
              job_name = "node";
              scrape_timeout = "45s"; # heavy: systemd + processes + textfile
              static_configs = [ { targets = cfg.scrapeTargets; } ];
            }
            {
              job_name = "smartctl";
              static_configs = [
                {
                  targets = cfg.smartctlTargets;
                }
              ];
            }
          ]
          # `null to disable` per the option's description. It used to emit the
          # job regardless, which produced `targets = [ null ]` and a type
          # error rather than the documented no-op; nothing sets it to null
          # today, and now nothing has to.
          ++ lib.optional (cfg.cloudflaredTarget != null) {
            job_name = "cloudflared";
            static_configs = [
              {
                targets = [ cfg.cloudflaredTarget ];
                labels = {
                  # cloudflared is scraped from wherever the tunnel runs,
                  # which is not necessarily this host - so the instance label
                  # comes from the target rather than from
                  # `networking.hostName`, which would mislabel every series
                  # the peer scrapes.
                  instance = lib.head (lib.splitString ":" cfg.cloudflaredTarget);
                };
              }
            ];
          }
          ++ [
            {
              job_name = "blackbox-http";
              metrics_path = "/probe";
              params = {
                module = [ "http_2xx" ];
              };
              static_configs = [
                {
                  targets = map (p: p.url) cfg.httpProbes;
                }
              ]
              # The peer's endpoints, one target per probe so each carries
              # which away host it is watching. `kind="remote"` lets
              # HostUnreachableFromOutside select exactly these and keeps
              # `ServiceDown` scoped to a host's own probes - without the
              # label, a failing away-host series would match both rules.
              # `host` is who the probe is watching, and is what
              # HostUnreachableFromOutside names.
              #
              # The remote target is the away host's dedicated host-alive
              # beacon (modules/services/host-alive.nix), not one of its real
              # services, so `ServiceDown` and HostUnreachableFromOutside stay
              # distinct: a crashed app fires only the warning, while a host
              # that is actually out of reach (which also takes every service
              # it runs with it) may co-fire the critical with any of its
              # services' own warnings. That is the intended separation.
              ++ (map (p: {
                targets = [ p.url ];
                labels = {
                  kind = "remote";
                  host = p.name;
                };
              }) cfg.remoteProbes);
              relabel_configs = [
                {
                  source_labels = [ "__address__" ];
                  target_label = "__param_target";
                }
                {
                  source_labels = [ "__param_target" ];
                  target_label = "instance";
                }
                {
                  target_label = "__address__";
                  replacement = "localhost:9115";
                }
              ];
            }
          ];

          ruleFiles = [ ./alert-rules.yml ];
          alertmanagers = lib.mkIf cfg.alertmanager.enable [
            {
              static_configs = [
                { targets = [ "localhost:9093" ]; }
              ];
            }
          ];
        };
      })

      # ============================================================
      # Alertmanager
      # ============================================================
      (lib.mkIf cfg.alertmanager.enable {
        # Where silences live, so it is worth a hostname - on the one host
        # that gets one, for the reason given against the Prometheus UI
        # above. Both hosts run an Alertmanager; they are clustered, so a
        # silence set through this one reaches the peer anyway.
        cg.publish = lib.mkIf cfg.grafana.enable {
          alertmanager.port = config.services.prometheus.alertmanager.port;
        };

        # Ensure alertmanager user exists before sops-nix runs
        users.users.alertmanager = {
          isSystemUser = true;
          group = "alertmanager";
        };

        users.groups.alertmanager = { };
        sops.secrets."monitoring/proton_smtp_token" = {
          owner = "alertmanager";
          group = "alertmanager";
        };

        # ==========================================================
        # Routing design
        #
        # Two lanes, deliberately unequal:
        #
        #   push  - ntfy on the phone. Criticals buzz (priority urgent),
        #           warnings arrive silently (priority low) and are muted
        #           overnight. Resolutions follow their alert's route, so a
        #           resolved critical lands as an ordinary-priority all-clear.
        #   email - the archive lane. Everything reaches it (the severity
        #           routes `continue` past the push receiver into this one),
        #           grouped by alertname so a fan-out of related alerts is
        #           one message, repeating no more often than daily.
        #
        # Inhibition keeps one root cause from fanning out into many
        # notifications: an unreachable host suppresses every alert sourced
        # from its exporters, a downed tunnel suppresses the probe failures
        # it would otherwise cause in bulk, and a pool-level ZFS failure
        # supersedes the per-symptom alerts describing the same disks.
        # ==========================================================

        services.prometheus.alertmanager = {
          enable = true;

          clusterPeers = cfg.alertmanager.clusterPeers;
          configuration = {
            global.resolve_timeout = "5m";

            route = {
              receiver = "email";
              group_by = [ "alertname" ];
              group_wait = "30s";
              group_interval = "10m";
              repeat_interval = "24h";

              routes = lib.optionals cfg.alertmanager.ntfy.enable [
                # Tunnel outages inside the nightly maintenance window are the
                # upgrade rebooting the host that owns the tunnel - expected,
                # not an incident. Criticals normally ignore quiet hours by
                # design, so this route is the carve-out: only tunnel alerts
                # are muted during it, a ZFS pool fault or failed verification
                # at 04:30 still pages, and a tunnel still down when the
                # window ends notifies then. See the maintenance-window
                # interval below.
                {
                  receiver = "push";
                  continue = true; # email still archives it
                  matchers = [
                    "severity = \"critical\""
                    "alertname =~ \"CloudflareTunnel.*\""
                  ];
                  group_by = [
                    "alertname"
                    "instance"
                  ];
                  group_wait = "30s";
                  repeat_interval = "4h";
                  mute_time_intervals = [ "maintenance-window" ];
                }
                {
                  receiver = "push";
                  continue = true; # email still archives it
                  matchers = [ "severity = \"critical\"" ];
                  group_by = [
                    "alertname"
                    "instance"
                  ];
                  group_wait = "30s";
                  repeat_interval = "4h";
                }
                {
                  receiver = "push";
                  continue = true;
                  matchers = [ "severity = \"warning\"" ];
                  group_by = [
                    "alertname"
                    "instance"
                  ];
                  # Warnings get a longer grace period before the first
                  # notification: most clear themselves.
                  group_wait = cfg.alertmanager.ntfy.warningGroupWait;
                  repeat_interval = "24h";
                  mute_time_intervals = lib.optionals cfg.alertmanager.quietHours.enable [ "overnight" ];
                }
              ];
            };

            mute_time_intervals =
              (lib.optionals (cfg.alertmanager.ntfy.enable && cfg.alertmanager.quietHours.enable) [
                {
                  name = "overnight";
                  time_intervals = [
                    {
                      times = [
                        {
                          start_time = cfg.alertmanager.quietHours.start;
                          end_time = "23:59";
                        }
                        {
                          start_time = "00:00";
                          end_time = cfg.alertmanager.quietHours.end;
                        }
                      ];
                      location = muteLocation;
                    }
                  ];
                }
              ])
              ++ lib.optionals cfg.alertmanager.ntfy.enable [
                # The servers' nightly auto-upgrade window: homelab01 starts
                # at 04:00 and homelab02 at 04:15, each with up to 10m of
                # randomized delay, and both reboot inside it
                # (system.autoUpgrade.rebootWindow, hosts/*/default.nix).
                # The tunnel lives on homelab01, so its reboots take the
                # CloudflareTunnel* criticals down with it - a mute that did
                # not exist left those buzzing at 04:15. Kept in step with
                # the UnexpectedReboot alert's 04:00-05:00 exclusion.
                {
                  name = "maintenance-window";
                  time_intervals = [
                    {
                      times = [
                        {
                          start_time = "04:00";
                          end_time = "05:00";
                        }
                      ];
                      location = muteLocation;
                    }
                  ];
                }
              ];

            inhibit_rules =
              let
                # Alerts that describe symptoms of a degraded ZFS pool rather
                # than the pool's state itself.
                zfsSymptoms = "Zfs(ChecksumErrors|IOErrors|ScrubErrors|ScrubOverdue)";
              in
              [
                # When Prometheus cannot reach a host's node_exporter, every
                # other metric sourced from that host is stale, and each of
                # those alerts firing separately is noise around the one real
                # problem. Textfile-derived alerts (restic, deploy, gluetun,
                # garden) carry instance too, so they are covered as well.
                {
                  source_matchers = [ "alertname = TargetDown" ];
                  target_matchers = [ "severity =~ warning|critical" ];
                  equal = [ "instance" ];
                }

                # A dead tunnel breaks every published service at once; the
                # dozen resulting ServiceDown failures say nothing the tunnel
                # alert does not. Probes that fail while the tunnel is healthy
                # are unaffected and still page normally.
                #
                # HostUnreachableFromOutside is deliberately *not* inhibited
                # here. It is the item-9 away-host beacon, and the tunnel owner
                # is exactly the host whose loss matters most: if homelab01
                # (which owns the tunnel) dies or loses egress, its own
                # cloudflared is gone with it, so the tunnel alert - whose
                # metric lives on that host - may itself never reach an
                # operator. The peer's reachability beacon is the one signal
                # that still can, so a tunnel outage must never silence it.
                {
                  source_matchers = [
                    "alertname =~ CloudflareTunnel(Down|ServiceFailed|NoConnections)"
                  ];
                  target_matchers = [ "alertname = ServiceDown" ];
                }

                # A degraded or faulted pool already says what checksum/IO
                # errors and overdue scrubs would say, with more urgency.
                {
                  source_matchers = [ "alertname =~ ZfsPool(Degraded|Faulted)" ];
                  target_matchers = [ "alertname =~ ${zfsSymptoms}" ];
                  equal = [
                    "instance"
                    "pool"
                  ];
                }

                # Critical disk pressure makes the warning redundant.
                {
                  source_matchers = [ "alertname = DiskSpaceCritical" ];
                  target_matchers = [ "alertname = DiskSpaceLow" ];
                  equal = [
                    "instance"
                    "mountpoint"
                  ];
                }
              ];

            receivers = [
              {
                name = "email";
                email_configs = [
                  {
                    to = cfg.alertmanager.email.to;
                    from = cfg.alertmanager.email.from;
                    smarthost = cfg.alertmanager.email.smarthost;
                    auth_username = cfg.alertmanager.email.authUsername;
                    auth_password_file = config.sops.secrets."monitoring/proton_smtp_token".path;
                    send_resolved = true;
                  }
                ];
              }
            ]
            ++ lib.optionals cfg.alertmanager.ntfy.enable [
              {
                name = "push";
                webhook_configs = [
                  {
                    # Derived from the bridge's port so there is one literal,
                    # not two that can drift apart.
                    url = "http://127.0.0.1:${toString cfg.alertmanager.ntfy.port}/hook";
                    send_resolved = true;
                    http_config.basic_auth = {
                      username = "alertmanager";
                      password_file = config.sops.secrets.${cfg.alertmanager.ntfy.webhookPasswordSecret}.path;
                    };
                  }
                ];
              }
            ];
          };
        };
        networking.firewall.allowedTCPPorts = [ 9094 ]; # gossip
      })

      # ============================================================
      # ntfy bridge: Alertmanager webhooks -> self-hosted ntfy
      # ============================================================
      # One bridge per host, next to that host's Alertmanager, so push
      # delivery does not depend on either host being the sole survivor -
      # both bridges publish to the same ntfy server over HTTPS and
      # Alertmanager's cluster deduplicates the result exactly as it does
      # for email.
      (lib.mkIf (cfg.alertmanager.enable && cfg.alertmanager.ntfy.enable) {
        # Only ever consumed through the rendered template below, which
        # sops-nix writes as root; nothing reads this file directly.
        sops.secrets.${cfg.alertmanager.ntfy.tokenSecret} = { };

        # Alertmanager reads this one itself when delivering to the local
        # bridge's /hook endpoint, so it must be readable by the service
        # user. The root:root 0400 default made every push delivery fail
        # with "permission denied" while the behaviour test stayed green -
        # its fixtures are world-readable store paths, so ownership bugs
        # cannot reproduce there. Same shape as proton_smtp_token above.
        sops.secrets.${cfg.alertmanager.ntfy.webhookPasswordSecret} = {
          owner = "alertmanager";
          group = "alertmanager";
        };

        # Merged over the plain-text settings at runtime so neither
        # credential ever lands in the store. The bridge reads these via
        # systemd LoadCredential, which PID1 opens before dropping
        # privileges, so the file's owner does not matter - 0400 root.
        #
        # The incoming-auth block must be `http.auth`, not `http.basic`:
        # alertmanager-ntfy (as of 1.2.1) silently ignores unknown keys, so
        # a `basic:` there disables /hook authentication entirely and the
        # only symptom is a startup warning in the journal.
        sops.templates."monitoring/ntfy/alertmanager-ntfy-auth" = {
          content = ''
            http:
              auth:
                username: alertmanager
                password: "${config.sops.placeholder.${cfg.alertmanager.ntfy.webhookPasswordSecret}}"
            ntfy:
              auth:
                token: "${config.sops.placeholder.${cfg.alertmanager.ntfy.tokenSecret}}"
          '';
          mode = "0400";
        };

        services.prometheus.alertmanager-ntfy = {
          enable = true;
          settings = {
            http.addr = "127.0.0.1:${toString cfg.alertmanager.ntfy.port}";
            ntfy = {
              baseurl = cfg.alertmanager.ntfy.baseUrl;
              notification = {
                topic = cfg.alertmanager.ntfy.topic;
                # Per-alert gval expression over the alert's own fields:
                # critical firing buzzes, warnings stay silent, resolutions
                # land at ordinary priority regardless of severity.
                priority = ''
                  status == "firing" ? (labels["severity"] == "critical" ? "urgent" : "low") : "default"
                '';
                tags = [
                  {
                    tag = "rotating_light";
                    condition = ''status == "firing" && labels["severity"] == "critical"'';
                  }
                  {
                    tag = "red_circle";
                    condition = ''status == "firing" && labels["severity"] == "warning"'';
                  }
                  {
                    tag = "green_circle";
                    condition = ''status == "resolved"'';
                  }
                ];
              };
            };
          };
          extraConfigFiles = [ config.sops.templates."monitoring/ntfy/alertmanager-ntfy-auth".path ];
        };
      })

      # ============================================================
      # Grafana
      # ============================================================
      (lib.mkIf cfg.grafana.enable {
        # Grafana binds 127.0.0.1 (see the server settings below), so the
        # proxy is the only way in.
        cg.publish.grafana.port = config.services.grafana.settings.server.http_port;

        # Ensure grafana user exists before sops-nix runs
        users.users.grafana = {
          isSystemUser = true;
          group = "grafana";
        };
        users.groups.grafana = { };

        sops.secrets = {
          "monitoring/grafana/username" = {
            owner = "grafana";
            group = "grafana";
          };
          "monitoring/grafana/password" = {
            owner = "grafana";
            group = "grafana";
          };
          "monitoring/grafana/secret_key" = {
            owner = "grafana";
            group = "grafana";
          };
        };

        services.grafana = {
          enable = true;

          settings = {
            security = {
              admin_user = "$__file{${config.sops.secrets."monitoring/grafana/username".path}}";
              admin_password = "$__file{${config.sops.secrets."monitoring/grafana/password".path}}";
              secret_key = "$__file{${config.sops.secrets."monitoring/grafana/secret_key".path}}";
            };
            server = {
              http_port = 3000;
              http_addr = "127.0.0.1";
              domain = "grafana.${fleet.domain}";
              root_url = "https://grafana.${fleet.domain}";
            };

            "auth.anonymous".enabled = false;
          };

          provision = {
            enable = true;

            datasources.settings.datasources = [
              {
                name = "Prometheus";
                type = "prometheus";
                url = "http://localhost:9090";
                isDefault = true;
                # Deliberately no `uid`: this host already has this datasource
                # with its auto-generated one, and re-provisioning it under a
                # different uid sends Grafana 13's provisioning into a fatal
                # "data source not found" crash loop on startup. Panels in the
                # provisioned dashboards reference the default datasource
                # rather than a pinned uid for the same reason.
              }
            ];

            # The fleet overview is the answer to "is anything wrong right
            # now" - firing alerts, unreachable targets, backup and upgrade
            # verdicts, per-host vitals - kept in code so it survives
            # reinstatement of /var/lib/grafana and cannot drift between hosts.
            dashboards.settings.providers = [
              {
                name = "fleet";
                type = "file";
                # Realized as its own store path rather than `toString
                # ./dashboards`: a bare flake-source path is baked into the
                # provider YAML without string context, so the directory is
                # only ever present if something unrelated happens to pull the
                # whole source tree into the system closure. On homelab01 that
                # something was the home-manager manifests; in the behaviour
                # test's minimal VM nothing did, provisioning logged
                # "Cannot read directory" at warn level, and Grafana came up
                # serving zero dashboards. See checks/grafana.nix.
                options.path = toString (
                  builtins.path {
                    name = "grafana-dashboards";
                    path = ./dashboards;
                  }
                );
              }
            ];
          };
        };
      })

      # ============================================================
      # VPN
      # ============================================================
      (lib.mkIf cfg.vpn.enable {
        sops.secrets.${cfg.vpn.gluetunApiKeySecret} = { };

        systemd.services.gluetun-health-exporter = {
          description = "Export Gluetun VPN health metrics for Prometheus";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = gluetunHealthScript;
            User = "root";
          };
        };

        systemd.timers.gluetun-health-exporter = {
          description = "Timer for Gluetun health metrics exporter";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "1min";
            OnUnitActiveSec = "1min";
            Unit = "gluetun-health-exporter.service";
          };
        };
      })
    ]
  );
}
