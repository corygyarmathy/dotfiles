# Minimal monitoring
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.cg.service.monitoring;
in
{
  options.cg.service.monitoring = {
    enable = lib.mkEnableOption "Monitoring stack";

    role = lib.mkOption {
      type = lib.types.enum [
        "hub"
        "agent"
      ];
      default = "agent";
      description = ''
        Role of this host in the monitoring architecture:
        - hub: Runs Prometheus, Alertmanager, Grafana, and exporters
        - agent: Runs only exporters (node_exporter, smartctl_exporter)
      '';
    };

    # Targets for Prometheus to scrape (hub only)
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

    # Alerting configuration
    alerting = {
      enable = lib.mkEnableOption "Alerting via Apprise";

      apprise = {
        port = lib.mkOption {
          type = lib.types.port;
          default = 8000;
          description = "Port for Apprise API to listen on";
        };
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # ========================================================================
      # Always applied (both hub and agent)
      # ========================================================================
      {
        services.prometheus.exporters = {
          node = {
            enable = true;
            enabledCollectors = [
              "systemd"
              "processes"
            ];
            listenAddress = "0.0.0.0";
            port = 9100;
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

      # ========================================================================
      # Hub only - blackbox exporter
      # ========================================================================
      (lib.mkIf (cfg.role == "hub") {
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
      })

      # ========================================================================
      # Hub only - Prometheus server
      # ========================================================================
      (lib.mkIf (cfg.role == "hub") {
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

          alertmanagers = lib.mkIf cfg.alerting.enable [
            {
              static_configs = [
                {
                  targets = [ "localhost:9093" ];
                }
              ];
            }
          ];
        };
      })

      # ========================================================================
      # Hub + alerting - Alertmanager
      # ========================================================================
      (lib.mkIf (cfg.role == "hub" && cfg.alerting.enable) {
        services.prometheus.alertmanager = {
          enable = true;

          configuration = {
            route = {
              receiver = "apprise";
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
                name = "apprise";
                webhook_configs = [
                  {
                    url = "http://localhost:${toString cfg.alerting.apprise.port}/notify/apprise";
                    send_resolved = true;
                  }
                ];
              }
            ];
          };
        };
      })

      # ========================================================================
      # Hub + alerting - Sops secrets and Apprise container
      # ========================================================================
      (lib.mkIf (cfg.role == "hub" && cfg.alerting.enable) {
        sops.secrets."monitoring/proton_smtp_token" = { };

        sops.templates."apprise-config" = {
          content = ''
            urls:
              - "mailtos://alerts@gyarmathy.co:${
                config.sops.placeholder."monitoring/proton_smtp_token"
              }@smtp.protonmail.ch:587/?from=alerts@gyarmathy.co&to=cory@gyarmathy.co&name=Homelab%20Alerts"
          '';
          owner = "root";
          mode = "0400";
        };

        virtualisation.oci-containers.containers.apprise-api = {
          image = "caronc/apprise:latest";
          ports = [ "127.0.0.1:${toString cfg.alerting.apprise.port}:8000" ];
          volumes = [
            "${config.sops.templates."apprise-config".path}:/config/apprise.yml:ro"
          ];
          extraOptions = [ "--pull=newer" ];
        };
      })

      # ========================================================================
      # Hub only - Grafana
      # ========================================================================
      (lib.mkIf (cfg.role == "hub") {
        services.grafana = {
          enable = true;

          settings = {
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
    ]
  );
}
