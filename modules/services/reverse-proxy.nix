# Reverse Proxy - Caddy with proper TLS
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.cg.service.reverse-proxy;
  domain = "gyarmathy.co";

  # Helper to reduce repetition
  mkProxy = port: {
    extraConfig = ''
      reverse_proxy localhost:${toString port}
    '';
  };
in
{
  options.cg.service.reverse-proxy = {
    enable = lib.mkEnableOption "Reverse proxy service (using caddy)";

    # You'd put your Cloudflare API token in sops
    # for DNS-01 challenge
  };

  config = lib.mkIf cfg.enable {
    services.caddy = {
      enable = true;

      # For DNS-01 challenge with Cloudflare
      # package = pkgs.caddy.withPlugins {
      #   plugins = [ "github.com/caddy-dns/cloudflare" ];
      #   hash = "...";  # Get this by building once
      # };

      globalConfig = ''
        # If using DNS challenge:
        # acme_dns cloudflare {env.CF_API_TOKEN}
      '';

      virtualHosts = {
        # Media - Client facing
        "jellyfin.${domain}" = mkProxy 8096;
        "requests.${domain}" = mkProxy 5055;
        "invite.${domain}" = mkProxy 5690; # Wizarr

        # Arr stack - Admin
        "sonarr.${domain}" = mkProxy 8989;
        "radarr.${domain}" = mkProxy 7878;
        "prowlarr.${domain}" = mkProxy 9696;
        "bazarr.${domain}" = mkProxy 6767;
        "downloads.${domain}" = mkProxy 8080;

        # Management tools
        "huntarr.${domain}" = mkProxy 9705;
        "cleanuparr.${domain}" = mkProxy 5000;
        "grafana.${domain}" = mkProxy 3000;
      };
    };

    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
  };
}
