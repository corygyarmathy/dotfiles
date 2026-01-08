# Reverse Proxy - Caddy
# Provides nice URLs for all services (e.g., jellyfin.home.local)
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.cg.service.reverse-proxy;
in
{
  options.cg.reverse-proxy.enable = lib.mkEnableOption "Reverse proxy service (using caddy)";

  config = lib.mkIf cfg.enable {

    services.caddy = {
      enable = true;

      # Virtual hosts for each service
      # These use .home.local domain - you'll need to add DNS entries
      # to DNS Server (DNS Rewrites) pointing *.home.local to this server's IP
      virtualHosts = {
        # Media
        "jellyfin.home.local" = {
          extraConfig = ''
            reverse_proxy localhost:8096
          '';
        };

        "requests.home.local" = {
          extraConfig = ''
            reverse_proxy localhost:5055
          '';
        };

        # Arr stack
        "sonarr.home.local" = {
          extraConfig = ''
            reverse_proxy localhost:8989
          '';
        };

        "radarr.home.local" = {
          extraConfig = ''
            reverse_proxy localhost:7878
          '';
        };

        "prowlarr.home.local" = {
          extraConfig = ''
            reverse_proxy localhost:9696
          '';
        };

        "bazarr.home.local" = {
          extraConfig = ''
            reverse_proxy localhost:6767
          '';
        };

        "downloads.home.local" = {
          extraConfig = ''
            reverse_proxy localhost:8080
          '';
        };

        # Smart home & photos
        "hass.home.local" = {
          extraConfig = ''
            reverse_proxy localhost:8123
          '';
        };

        "photos.home.local" = {
          extraConfig = ''
            reverse_proxy localhost:2283
          '';
        };
      };
    };

    # Open firewall for HTTP/HTTPS
    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
  };
}
