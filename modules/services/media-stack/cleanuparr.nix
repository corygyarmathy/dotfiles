# Cleanuparr - Stalled Download Cleanup
# Automatically removes stalled, failed, or completed downloads from *arr apps
# and qBittorrent based on configurable rules.
#
# FEATURES:
# - Strike system to mark bad downloads
# - Remove and block downloads that fail to import
# - Remove stalled or metadata-stuck downloads
# - Remove low-speed or high-ETA downloads
# - Malware blocking with community-maintained blocklists
# - Cleanup downloads based on seeding time/ratio
# - Orphan/unlinked download management (with cross-seed support)
# - Notifications on strike or removal
#
# SETUP AFTER DEPLOYMENT:
# 1. Access web UI at http://hostname:11011
#
# 2. Add Download Client (Settings -> Download Clients):
#    - Name: qBittorrent
#    - Type: qBittorrent
#    - URL: http://qbittorrent:8080 (or via gluetun if VPN enabled)
#    - Username/Password: From your qBittorrent config
#    - Test connection before saving
#
# 3. Add *arr Applications (Settings -> Apps):
#    For Sonarr:
#      - Name: Sonarr
#      - URL: http://sonarr:8989
#      - API Key: From Sonarr Settings -> General
#
#    For Radarr:
#      - Name: Radarr
#      - URL: http://radarr:7878
#      - API Key: From Radarr Settings -> General
#
# 4. Configure Features (Settings):
#    Queue Cleaner:
#      - Enable and configure strike limits
#      - Set stall detection threshold
#      - Configure speed/ETA limits if desired
#
#    Download Cleaner (for ratio management):
#      - Enable for seeding cleanup
#      - Set category-specific rules (e.g., "sonarr", "radarr")
#      - Configure max ratio and seed times
#      - CAUTION: Enable "Delete Private Torrents" carefully for HnR compliance
#
#    Malware Blocker:
#      - Enable with default blocklist for *.lnk, *.zipx protection
#
# 5. Optional - Disable Auto Search (if using Huntarr):
#    Settings -> General -> Auto Search After Removal -> Disable
#    Let Huntarr handle replacement searches instead
#
# INTEGRATION WITH HUNTARR:
# Cleanuparr and Huntarr complement each other:
# - Cleanuparr: Removes bad/stuck/completed downloads
# - Huntarr: Searches for missing/upgradeable media
# Disable auto-search in Cleanuparr to avoid duplicate searches.
#
# PRIVATE TRACKER CONSIDERATIONS:
# For ratio-based cleanup with private trackers:
# - Set appropriate min seed times to meet tracker requirements
# - Use max ratio as secondary criteria
# - Consider using cross-seed to build ratio before cleanup
#
# NOTE ON DECLARATIVE CONFIG:
# Cleanuparr stores its configuration in a SQLite database via the web UI.
# Full declarative configuration is not currently supported by upstream.
# Service connections and rules must be configured manually after deployment.
#
# MIGRATION NOTES (homelab02 NAS):
# Cleanuparr can stay on homelab01 or move to homelab02.
# - Needs access to Sonarr/Radarr APIs (homelab01)
# - Needs access to qBittorrent API (homelab02 after migration)
# Decision: Keep on homelab01, connect to qBittorrent over network
{
  config,
  lib,
  ...
}:

let
  cfg = config.cg.service.cleanuparr;
  stack = config.cg.service.media-stack;
in
{
  options.cg.service.cleanuparr = {
    enable = lib.mkEnableOption "Cleanuparr stalled download cleanup";

    port = lib.mkOption {
      type = lib.types.port;
      default = 11011;
      description = "Port for Cleanuparr web UI";
    };

    basePath = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "/cleanuparr";
      description = "Base path for the web UI (for reverse proxy setups)";
    };
  };

  config = lib.mkIf cfg.enable {
    # Require media-stack infrastructure
    assertions = [
      {
        assertion = stack.enable;
        message = "cleanuparr requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
    ];

    # Create config directory
    systemd.tmpfiles.rules = [
      "d ${stack.configPath}/cleanuparr 0775 ${stack.user} ${stack.group} -"
    ];

    # Container definition
    virtualisation.oci-containers.containers.cleanuparr = {
      image = "ghcr.io/cleanuparr/cleanuparr:latest";
      environment = {
        TZ = config.time.timeZone;
        PORT = toString cfg.port;
        BASE_PATH = cfg.basePath;
        PUID = toString config.users.users.${stack.user}.uid;
        PGID = toString config.users.groups.${stack.group}.gid;
        UMASK = "022";
      };
      volumes = [
        "${stack.configPath}/cleanuparr:/config"
        # Mount downloads for hardlink detection (Download Cleaner feature)
        "${stack.dataPath}/downloads:/downloads"
      ];
      ports = [ "${toString cfg.port}:${toString cfg.port}" ];
      extraOptions = [
        "--pull=newer"
        "--network=arr-network"
        # Health check for container orchestration
        "--health-cmd=curl -sf http://localhost:${toString cfg.port}${cfg.basePath}/health || exit 1"
        "--health-interval=30s"
        "--health-timeout=10s"
        "--health-start-period=30s"
        "--health-retries=3"
      ];
    };

    # Ensure network exists before starting
    systemd.services.podman-cleanuparr = {
      after = [ "podman-network-arr.service" ];
      requires = [ "podman-network-arr.service" ];
    };

    # Firewall
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
