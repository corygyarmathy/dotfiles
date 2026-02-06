# Cloudflare Tunnel - Zero Trust network access
#
# Provides:
# - Secure tunnel to Cloudflare edge without opening firewall ports
# - Automatic DNS management via tunnel routing
# - Protection against DDoS and direct IP exposure
#
# Architecture:
# - cloudflared daemon runs on homelab01
# - Creates outbound tunnel to Cloudflare
# - Cloudflare routes traffic based on hostname to local services
# - Works through CGNAT and dynamic IPs
#
# Prerequisites:
# - Cloudflare account with domain
# - Tunnel created via: cloudflared tunnel create <name>
# - Credentials stored in sops
#
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.service.cloudflare-tunnel;

in
{
  options.cg.service.cloudflare-tunnel = {
    enable = lib.mkEnableOption "Cloudflare Tunnel for zero-trust access";

    domain = lib.mkOption {
      type = lib.types.str;
      default = "gyarmathy.co";
      description = "Domain name for services";
    };

    services = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            subdomain = lib.mkOption {
              type = lib.types.str;
              description = "Subdomain for this service";
            };
            port = lib.mkOption {
              type = lib.types.port;
              description = "Local port the service listens on";
            };
            localOnly = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "If true, exclude from tunnel (local network only)";
            };
          };
        }
      );
      default = { };
      description = "Services to expose through the tunnel";
    };
  };

  config = lib.mkIf cfg.enable {
    # Cloudflare tunnel credentials and ID
    sops = {
      secrets."cloudflare/tunnel-credentials" = {
        sopsFile = ../../secrets/homelab.yaml;
        owner = "cloudflared";
        group = "cloudflared";
        mode = "0400";
        restartUnits = [ "cloudflared-tunnel.service" ];
      };

      secrets."cloudflare/tunnel-id" = {
        sopsFile = ../../secrets/homelab.yaml;
        owner = "cloudflared";
        group = "cloudflared";
        mode = "0400";
        restartUnits = [ "cloudflared-tunnel.service" ];
      };

      # Generate cloudflared config using sops template
      # This allows us to inject the tunnel ID from secrets
      templates."cloudflared-config.yml" = {
        content = builtins.toJSON {
          tunnel = config.sops.placeholder."cloudflare/tunnel-id";
          credentials-file = config.sops.secrets."cloudflare/tunnel-credentials".path;

          # Ingress rules - routes traffic based on hostname
          ingress =
            # Public services only (where localOnly = false)
            (lib.mapAttrsToList (name: svc: {
              hostname = "${svc.subdomain}.${cfg.domain}";
              service = "http://localhost:${toString svc.port}";
              originRequest = {
                httpHostHeader = "${svc.subdomain}.${cfg.domain}";
                noTLSVerify = true;
              };
            }) (lib.filterAttrs (_: svc: !svc.localOnly) cfg.services))

            # Required catch-all rule
            ++ [
              {
                service = "http_status:404";
              }
            ];
        };
        owner = "cloudflared";
        group = "cloudflared";
        mode = "0400";
      };
    };

    # Create cloudflared user
    users.users.cloudflared = {
      isSystemUser = true;
      group = "cloudflared";
      description = "Cloudflare Tunnel daemon user";
    };

    users.groups.cloudflared = { };

    # Cloudflared tunnel service
    systemd.services.cloudflared-tunnel = {
      description = "Cloudflare Tunnel";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        User = "cloudflared";
        Group = "cloudflared";
        ExecStart = "${pkgs.cloudflared}/bin/cloudflared tunnel --config ${
          config.sops.templates."cloudflared-config.yml".path
        } run";
        Restart = "on-failure";
        RestartSec = "5s";

        # Security hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
      };
    };
  };
}
