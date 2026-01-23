# Reverse Proxy - Caddy with Automatic TLS via DNS Challenge
#
# Provides:
# - Reverse proxy for all homelab services
# - Automatic TLS certificates from Let's Encrypt
# - DNS-01 challenge via Cloudflare (works for internal-only services)
# - Individual certificates per service (as requested for learning)
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
#   "*.gyarmathy.co" = { ... }
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
  domain = "gyarmathy.co";

  # Build Caddy with Cloudflare DNS plugin
  # This is required for DNS-01 challenge
  #
  # To find the latest plugin version:
  #   nix-shell -p go
  #   go mod init temp
  #   go get github.com/caddy-dns/cloudflare
  #   grep 'caddy-dns/cloudflare' go.mod
  #
  caddyWithCloudflare = pkgs.caddy.withPlugins {
    plugins = [ "github.com/caddy-dns/cloudflare@v0.2.2" ];
    # NOTE: If build fails with hash mismatch, update this value
    # Leave empty ("") on first build to get the correct hash from error output
    hash = "sha256-dnhEjopeA0UiI+XVYHYpsjcEI6Y1Hacbi28hVKYQURg=";
  };

  # Helper to create a reverse proxy virtual host with TLS
  # Each service gets its own cert via DNS-01 challenge
  mkProxyHost =
    {
      subdomain,
      port,
      # Optional: restrict to local network only
      localOnly ? false,
      # Optional: extra Caddy config
      extraConfig ? "",
    }:
    {
      "${subdomain}.${domain}" = {
        extraConfig = ''
          ${lib.optionalString (!localOnly) ''
            header {
              X-Frame-Options "SAMEORIGIN" # Prevent clickjacking
              X-Content-Type-Options "nosniff" # Prevent MIME sniffing
              X-XSS-Protection "1; mode=block" # Enable XSS filter
              Referrer-Policy "strict-origin-when-cross-origin" # Referrer policy
              # HSTS (uncomment when ready - be careful, this is sticky. Requires TLS to be working.)
              # Strict-Transport-Security "max-age=31536000; includeSubDomains"
            }
          ''}

          ${lib.optionalString localOnly ''
            # Restrict to local network only
            @denied not remote_ip 10.20.2.0/24 192.168.0.0/16 127.0.0.1
            respond @denied "Access denied" 403
          ''}

          reverse_proxy localhost:${toString port} {
            # Recommended headers for proxied services
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
          }

          ${extraConfig}
        '';
      };
    };

  # Service definitions - add new services here
  # Format: { subdomain, port, localOnly (optional), extraConfig (optional) }
  #
  # NOTE: Services marked localOnly = true will only be accessible from
  # the local network, even if exposed via Cloudflare tunnel later
  services = {
    # ── Media - User Facing ─────────────────────────────────────────────
    jellyfin = {
      subdomain = "jellyfin";
      port = 8096;
      localOnly = false; # Users need external access
    };
    requests = {
      subdomain = "requests";
      port = 5055; # Jellyseerr
      localOnly = false; # Users can request externally
    };
    invite = {
      subdomain = "invite";
      port = 5690; # Wizarr
      localOnly = false; # Invite links need to work externally
    };

    # ── Media - Admin ────────────────────────────────────────────────────
    sonarr = {
      subdomain = "sonarr";
      port = 8989;
      localOnly = true; # Admin only
    };
    radarr = {
      subdomain = "radarr";
      port = 7878;
      localOnly = true;
    };
    prowlarr = {
      subdomain = "prowlarr";
      port = 9696;
      localOnly = true;
    };
    bazarr = {
      subdomain = "bazarr";
      port = 6767;
      localOnly = true;
    };
    downloads = {
      subdomain = "downloads";
      port = 8080; # qBittorrent
      localOnly = true;
    };

    # ── Management Tools ─────────────────────────────────────────────────
    huntarr = {
      subdomain = "huntarr";
      port = 9705;
      localOnly = true;
    };
    cleanuparr = {
      subdomain = "cleanuparr";
      port = 11011;
      localOnly = true;
    };
    recyclarr = {
      subdomain = "recyclarr";
      port = 7700; # If recyclarr has a web UI
      localOnly = true;
    };

    # ── Monitoring ───────────────────────────────────────────────────────
    grafana = {
      subdomain = "grafana";
      port = 3000;
      localOnly = true;
    };
    prometheus = {
      subdomain = "prometheus";
      port = 9090;
      localOnly = true;
    };

    # ── Infrastructure ───────────────────────────────────────────────────
    adguard = {
      subdomain = "adguard";
      port = 3080; # AdGuard Home web UI (same port, but accessed via subdomain)
      localOnly = true;
    };

    # Add more services as needed...
  };

  # Convert services attrset to virtualHosts format
  allVirtualHosts = lib.foldl' (acc: svc: acc // (mkProxyHost svc)) { } (lib.attrValues services);

in
{
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
      sopsFile = ../../secrets/homelab.yaml;

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
      package = caddyWithCloudflare;

      # Global Caddy configuration
      globalConfig = ''
        # Email for Let's Encrypt
        email ${cfg.email}

        # Use Let's Encrypt production (comment out for testing)
        acme_ca https://acme-v02.api.letsencrypt.org/directory

        # Global DNS challenge config using environment variable
        # The token is loaded via systemd EnvironmentFile
        acme_dns cloudflare {env.CF_API_TOKEN}
      '';

      # All virtual hosts with TLS
      virtualHosts = allVirtualHosts;
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
