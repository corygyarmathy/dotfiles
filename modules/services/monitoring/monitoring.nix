# Minimal monitoring
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.cg.service.monitoring;

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

    API_KEY=$(cat "$CREDENTIALS_DIRECTORY/gluetun-api-key")
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

    };

    # ZFS monitoring
    zfs = {
      enable = lib.mkEnableOption "ZFS pool health monitoring";
    };

    # Targets for Prometheus to scrape
    scrapeTargets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "homelab01:9100"
        "homelab02:9100"
      ];
      description = "List of node_exporter targets to scrape";
    };

    smartctlTargets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "homelab01:9633"
        "homelab02:9633"
      ];
      description = "List of smartctl_exporter targets to scrape";
    };

    # HTTP endpoints to probe
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
      default = [ ];
      description = "HTTP endpoints to probe with blackbox_exporter";
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
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # ============================================================
      # Always: exporters (node, smartctl, firewall)
      # ============================================================
      {
        services.prometheus.exporters = {
          node = {
            enable = true;
            enabledCollectors = [
              "systemd"
              "processes"
            ]
            ++ lib.optionals cfg.zfs.enable [
              "textfile"
            ];
            listenAddress = "0.0.0.0";
            port = 9100;
            extraFlags = lib.optionals cfg.zfs.enable [
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
          scrapeConfigs = [
            {
              job_name = "node";
              static_configs = [
                {
                  targets = cfg.scrapeTargets;
                }
              ];
            }
            {
              job_name = "smartctl";
              static_configs = [
                {
                  targets = cfg.smartctlTargets;
                }
              ];
            }
            {
              job_name = "cloudflared";
              static_configs = [
                {
                  targets = [ cfg.cloudflaredTarget ];
                  labels = {
                    instance = "homelab01";
                  };
                }
              ];
            }
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
              ];
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

        services.prometheus.alertmanager = {
          enable = true;

          clusterPeers = cfg.alertmanager.clusterPeers;
          configuration = {
            route = {
              receiver = "email";
              group_by = [
                "alertname"
                "instance"
              ];
              group_wait = "30s";
              group_interval = "5m";
              repeat_interval = "4h";
            };

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
            ];
          };
        };
        networking.firewall.allowedTCPPorts = [ 9094 ]; # gossip
      })

      # ============================================================
      # Grafana
      # ============================================================
      (lib.mkIf cfg.grafana.enable {
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
              domain = "grafana.gyarmathy.co";
              root_url = "https://grafana.gyarmathy.co";
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
            LoadCredential = [
              "gluetun-api-key:${config.sops.secrets.${cfg.vpn.gluetunApiKeySecret}.path}"
            ];
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
