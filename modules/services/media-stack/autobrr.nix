# Autobrr - Torrent Automation
# Monitors IRC announce channels and RSS feeds from private trackers,
# catching new releases in real-time and pushing them to the download
# client. Works with Sonarr/Radarr filters to grab wanted content
# seconds after it's announced, rather than waiting for RSS poll cycles.
#
# SETUP AFTER DEPLOYMENT:
# 1. Access web UI at http://hostname:7474 (or via reverse proxy)
# 2. Create admin account on first launch
# 3. Add IRC networks for your private trackers
# 4. Add indexers (your trackers)
# 5. Add download client (qBittorrent at http://10.20.2.130:8080)
# 6. Create filters linked to Sonarr/Radarr for automatic grabbing
#
# HOW IT WORKS:
# Tracker IRC channel announces release → autobrr matches against filters
# → pushes .torrent to qBittorrent → Sonarr/Radarr detect & import
#
# This runs as a native NixOS service (not a container) using DynamicUser.
# State (SQLite DB, filters, IRC config) lives at /var/lib/autobrr.
# Config is fully declarative — regenerated from Nix settings on each start.
{
  config,
  lib,
  ...
}:

let
  cfg = config.cg.service.autobrr;
  stack = config.cg.service.media-stack;
in
{
  options.cg.service.autobrr = {
    enable = lib.mkEnableOption "Autobrr torrent automation";

    port = lib.mkOption {
      type = lib.types.port;
      default = 7474;
      description = "Port for Autobrr web UI";
    };
  };

  config = lib.mkIf cfg.enable {
    # Require media-stack infrastructure
    assertions = [
      {
        assertion = stack.enable;
        message = "autobrr requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
    ];

    # Autobrr session secret (generate with: nix-shell -p openssl --run "openssl rand -hex 32")
    sops.secrets."media-stack/autobrr/session-secret" = { };

    # Native NixOS Autobrr service
    services.autobrr = {
      enable = true;
      openFirewall = true;
      secretFile = config.sops.secrets."media-stack/autobrr/session-secret".path;
      settings = {
        host = "0.0.0.0";
        port = cfg.port;
        checkForUpdates = false;
      };
    };
  };
}
