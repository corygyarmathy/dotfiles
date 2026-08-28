# Cloudflare Tunnel - Zero Trust network access
#
# Provides:
# - Secure tunnel to Cloudflare edge without opening firewall ports
# - Automatic DNS management via tunnel routing
# - Protection against DDoS and direct IP exposure
#
# Architecture:
# - cloudflared daemon runs on the fleet's gateway host
# - Registers DNS routes in Cloudflare
# - Creates outbound tunnel to Cloudflare
# - Cloudflare routes traffic based on hostname to local services
# - Works through CGNAT and dynamic IPs
#
# Prerequisites:
# - Cloudflare account with domain
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

  # Build the list of public hostnames at eval time
  publicHostnames = map (svc: "${svc.subdomain}.${cfg.domain}") (
    lib.attrValues (lib.filterAttrs (_: svc: !svc.localOnly) cfg.services)
  );

  routeScript = pkgs.writeShellScript "cloudflared-route-dns" ''
    TUNNEL_ID=$(cat ${config.sops.secrets."cloudflare/tunnel-id".path})
    ${lib.concatMapStrings (hostname: ''
      echo "Registering DNS route for ${hostname}..."
      ${pkgs.cloudflared}/bin/cloudflared tunnel \
        --origincert ${config.sops.secrets."cloudflare/origin-cert".path} \
        route dns "$TUNNEL_ID" ${hostname} || true
    '') publicHostnames}
  '';
in
{
  # Reads config.cg.fleet, so it declares it - see modules/nixos/fleet.nix.
  imports = [ ../nixos/fleet.nix ];

  options.cg.service.cloudflare-tunnel = {
    enable = lib.mkEnableOption "Cloudflare Tunnel for zero-trust access";

    domain = lib.mkOption {
      type = lib.types.str;
      default = config.cg.fleet.domain;
      defaultText = lib.literalExpression "config.cg.fleet.domain";
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
              description = "Port the service listens on";
            };
            upstream = lib.mkOption {
              type = lib.types.str;
              default = "localhost";
              example = "homelab02";
              description = ''
                Host the service runs on. Defaults to this machine -- cloudflared
                bypasses Caddy and connects to the origin directly, so a service
                living on another node needs its hostname here too.
              '';
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
      secrets = {
        "cloudflare/tunnel-credentials" = {
          sopsFile = ../../secrets/homelab.yaml;
          owner = "cloudflared";
          group = "cloudflared";
          mode = "0400";
          restartUnits = [ "cloudflared-tunnel.service" ];
        };

        "cloudflare/tunnel-id" = {
          sopsFile = ../../secrets/homelab.yaml;
          owner = "cloudflared";
          group = "cloudflared";
          mode = "0400";
          restartUnits = [ "cloudflared-tunnel.service" ];
        };
        "cloudflare/origin-cert" = {
          sopsFile = ../../secrets/homelab.yaml;
          owner = "cloudflared";
          group = "cloudflared";
          mode = "0400";
        };
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
              service = "http://${svc.upstream}:${toString svc.port}";
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
        restartUnits = [ "cloudflared-tunnel.service" ];
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

    # Register cloudflare DNS routes
    systemd.services.cloudflared-route-dns = {
      description = "Register Cloudflare Tunnel DNS routes";
      after = [
        "network-online.target"
        "cloudflared-tunnel.service"
      ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "cloudflared";
        Group = "cloudflared";
        ExecStart = routeScript;
      };
    };

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
        ExecStart = "${pkgs.cloudflared}/bin/cloudflared tunnel --metrics 0.0.0.0:20241 --config ${
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
    # Expose metrics for monitoring
    networking.firewall.allowedTCPPorts = [ 20241 ];
  };
}
