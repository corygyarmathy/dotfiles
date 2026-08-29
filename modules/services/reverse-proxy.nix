# Reverse Proxy - Caddy with Automatic TLS via DNS Challenge
#
# Provides:
# - Reverse proxy for all homelab services
# - Automatic TLS certificates from Let's Encrypt
# - DNS-01 challenge via Cloudflare (works for internal-only services)
# - Individual certificates per service (as requested for learning)
#
# WHAT IT PROXIES:
# One vhost per entry in `cg.publish`, which the modules that run the services
# contribute to themselves - this module keeps no list of its own. See
# modules/nixos/publish.nix.
#
# Prerequisites:
# - Domain DNS managed by Cloudflare
# - Cloudflare API token with Zone:DNS:Edit permissions
# - Token stored in sops as "cloudflare/api-token"
#
# Certificate Strategy:
# - Each service gets its own certificate via DNS-01 challenge
# - No need for port 80/443 to be publicly accessible
# - Certs auto-renew before expiry
#
# To switch to wildcard later, change the virtualHosts to use:
#   "*.${domain}" = { ... }
# and add a single tls block with the dns challenge
#
# ════════════════════════════════════════════════════════════════════════════
# IMPORTANT: Hash Management for Caddy Plugins
# ════════════════════════════════════════════════════════════════════════════
# The `hash` value for withPlugins changes when:
#   1. Caddy version updates in nixpkgs
#   2. Plugin version changes
#
# To get the correct hash:
#   1. Set hash = "" (empty string)
#   2. Run: nixos-rebuild build
#   3. Copy the hash from the error message
#   4. Update the hash below
#
# This is a known limitation - see: https://github.com/nixos/nixpkgs/issues/450289
# ════════════════════════════════════════════════════════════════════════════
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.service.reverse-proxy;
  fleet = config.cg.fleet;
  inherit (fleet) domain;

  # Build Caddy with Cloudflare DNS plugin
  # This is required for DNS-01 challenge
  #
  # To find the latest plugin version:
  #   nix-shell -p go
  #   go mod init temp
  #   go get github.com/caddy-dns/cloudflare
  #   grep 'caddy-dns/cloudflare' go.mod
  #
  caddyWithPlugins = pkgs.caddy.withPlugins {
    plugins = [
      "github.com/caddy-dns/cloudflare@v0.2.2"
      "github.com/mholt/caddy-ratelimit@v0.1.0"
    ];
    # NOTE: If build fails with hash mismatch, update this value
    # Leave empty ("") on first build to get the correct hash from error output
    hash = "sha256-5d+U7sdSIUuwj6OK8WutZGsfvshtDj0FKRjkMDNfbxU=";
  };

  # Rate limiting profiles for different service types
  rateLimitProfiles = {
    # Media services - users click around frequently, load many thumbnails
    media = ''
      rate_limit {
        zone media_general {
          key {remote_host}
          events 1000    # 1000 requests per 10 min = ~100/min
          window 10m
        }
      }

      # API endpoints still need some protection but higher limits
      @api_paths {
        path /api/* /rest/*
      }
      rate_limit @api_paths {
        zone media_api {
          key {remote_host}
          events 500     # 500 requests per minute
          window 1m
        }
      }
    '';

    # Admin services - less traffic, stricter limits
    admin = ''
      rate_limit {
        zone admin_general {
          key {remote_host}
          events 300
          window 10m
        }
      }

      @api_paths {
        path /api/* /rest/*
      }
      rate_limit @api_paths {
        zone admin_api {
          key {remote_host}
          events 100
          window 1m
        }
      }
    '';

    # No rate limiting (for trusted or low-risk services)
    none = "";
  };

  # Helper to create a reverse proxy virtual host with TLS
  # Each service gets its own cert via DNS-01 challenge
  #
  # Takes a `cg.publish` entry whole, so every field it reads has already been
  # given a type and a default by modules/nixos/publish.nix rather than here.
  mkProxyHost =
    {
      subdomain,
      port,
      upstream,
      localOnly,
      rateLimitProfile,
      extraConfig,
      proxyExtraConfig,
      # `probe` and `probePath` are the monitoring consumer's business.
      ...
    }:
    {
      "${subdomain}.${domain}" = {
        extraConfig = ''
          ${lib.optionalString (!localOnly) ''
            # Security headers
            header {
              X-Frame-Options "SAMEORIGIN" # Prevent clickjacking
              X-Content-Type-Options "nosniff" # Prevent MIME sniffing
              X-XSS-Protection "1; mode=block" # Enable XSS filter
              Referrer-Policy "strict-origin-when-cross-origin" # Referrer policy
              # HSTS - enables after TLS is confirmed working
              Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
            }

            # Apply rate limiting based on profile
            ${rateLimitProfiles.${rateLimitProfile}}
          ''}

          ${lib.optionalString localOnly ''
            # Restrict to local network only
            @denied not remote_ip ${fleet.lan.cidr} 10.89.0.0/24 192.168.0.0/16 127.0.0.1
            respond @denied "Access denied" 403
          ''}

          reverse_proxy ${upstream}:${toString port} {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
            ${proxyExtraConfig}
          }

          ${extraConfig}
        '';
      };
    };
in
{
  # Reads config.cg.fleet and config.cg.publish, so it declares both - see
  # modules/nixos/fleet.nix and modules/nixos/publish.nix.
  imports = [
    ../nixos/fleet.nix
    ../nixos/publish.nix
  ];

  options.cg.service.reverse-proxy = {
    enable = lib.mkEnableOption "Caddy reverse proxy with automatic TLS";

    email = lib.mkOption {
      type = lib.types.str;
      description = "Email for Let's Encrypt account notifications";
      example = "admin@example.com";
    };

    cloudflareTokenFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to file containing Cloudflare API token";
      example = "/run/secrets/cloudflare-api-token";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open firewall for HTTP (80) and HTTPS (443)";
    };

    # Future: Options for exposing to internet
    # tunnel.enable = lib.mkEnableOption "Cloudflare Tunnel for external access";
  };

  config = lib.mkIf cfg.enable {
    # Cloudflare API token for Caddy DNS challenge
    # sops-nix creates this as an environment file that Caddy can read
    sops.secrets."cloudflare/api-token" = {
      # IMPORTANT: The secret value should be JUST the token, not "CF_API_TOKEN=..."
      # sops-nix will create the file, and we use a template to make it an env file
      owner = "caddy";
      group = "caddy";
      mode = "0400";
      restartUnits = [ "caddy.service" ];
    };

    # Create an environment file from the secret
    # This converts the raw token into CF_API_TOKEN=<token> format
    sops.templates."caddy-cloudflare-env" = {
      content = ''
        CF_API_TOKEN=${config.sops.placeholder."cloudflare/api-token"}
      '';
      owner = "caddy";
      group = "caddy";
      mode = "0400";
    };

    # Use Caddy with Cloudflare DNS plugin
    services.caddy = {
      enable = true;
      package = caddyWithPlugins;

      # Global Caddy configuration
      globalConfig = ''
        # Email for Let's Encrypt
        email ${cfg.email}

        # Use Let's Encrypt production (comment out for testing)
        acme_ca https://acme-v02.api.letsencrypt.org/directory

        # Global DNS challenge config using environment variable
        # The token is loaded via systemd EnvironmentFile
        # Sets resolvers to cloudflare dns to avoid split-horizon dns issues
        cert_issuer acme {
          dns cloudflare {env.CF_API_TOKEN}
          resolvers 1.1.1.1
        }
      '';

      # One vhost per published service. The registry is contributed to by
      # the modules that run the services (see modules/nixos/publish.nix), so
      # a port change in one of them moves the proxy with it instead of
      # leaving it pointed at nothing.
      virtualHosts = lib.foldl' (acc: svc: acc // (mkProxyHost svc)) { } (
        lib.attrValues config.cg.publish
      );
    };

    # Firewall
    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = [
        80 # HTTP (redirects to HTTPS)
        443 # HTTPS
      ];
    };

    # Caddy systemd service configuration
    systemd.services.caddy = {
      serviceConfig = {
        # Load Cloudflare token as environment variable
        # The file should contain: CF_API_TOKEN=your-token-here
        EnvironmentFile = cfg.cloudflareTokenFile;

        # Caddy needs to read the token file
        SupplementaryGroups = [ config.users.groups.keys.name or "keys" ];
      };
    };
  };
}
