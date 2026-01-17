# Cross-seed - Private Tracker Ratio Builder
# Finds torrents on your private trackers that match content you already have
# Pure upload - no additional downloads required
#
# HOW IT WORKS:
# 1. Scans your existing media library and qBittorrent torrent files
# 2. Searches your private trackers (via Torznab from Prowlarr) for matches
# 3. Injects matching torrents into qBittorrent for seeding
#
# SETUP AFTER DEPLOYMENT:
# 1. Access web UI at http://hostname:2468 (if behind VPN, access via VPN port)
# 2. Edit config at /srv/arr/cross-seed/config.js
# 3. Add Torznab URLs for your PRIVATE trackers only:
#    - Get URLs from Prowlarr: Indexers -> (tracker) -> Copy Torznab Feed
#    - Format: "http://prowlarr:9696/INDEX/api?apikey=YOUR_API_KEY"
# 4. Restart cross-seed container after config changes
#
# IMPORTANT:
# - Only add PRIVATE trackers - public trackers provide little ratio benefit
# - Cross-seed runs through VPN if qbittorrent.vpn.enable = true
#
# SOPS SECRETS REQUIRED (if using arr API integration):
# - media-stack/sonarr/api
# - media-stack/radarr/api
#
# MIGRATION NOTES (homelab02 NAS):
# Cross-seed will MOVE to homelab02 alongside qBittorrent.
# - Needs access to qBittorrent's torrent files and media library
# - Both are on the same host, so this is straightforward
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.cg.service.cross-seed;
  stack = config.cg.service.media-stack;
  qbt = config.cg.service.qbittorrent;

  # Default config template
  crossSeedConfig = pkgs.writeText "config.js" ''
    // Cross-seed configuration
    // Documentation: https://www.cross-seed.org/docs/basics/options
    
    module.exports = {
      // qBittorrent connection
      qbittorrentUrl: "http://localhost:8080",
      
      // Action: "inject" adds to qBittorrent, "save" just saves .torrent files
      action: "inject",
      
      // Where qBittorrent stores its .torrent files
      torrentDir: "/torrents",
      
      // Your media directories for data-based matching
      dataDirs: [
        "/data/tv",
        "/data/movies",
      ],
      
      // Output directory for matched torrents
      outputDir: "/config/output",
      
      // ========================================================================
      // IMPORTANT: Add your private tracker Torznab URLs here
      // Get from Prowlarr: Indexers -> (tracker) -> Copy Torznab Feed
      // Only add PRIVATE trackers - not public ones!
      // ========================================================================
      torznab: [
        // "http://prowlarr:9696/1/api?apikey=YOUR_PROWLARR_API_KEY",
      ],
      
      // Matching strictness: "safe" (strict) or "risky" (loose)
      matchMode: "safe",
      
      // Skip files smaller than this
      minFileSize: "100MB",
      
      // Category for injected torrents in qBittorrent
      qbitCategory: "cross-seed",
      
      // Search schedule (milliseconds)
      searchCadence: 24 * 60 * 60 * 1000,  // Daily
      rssCadence: 30 * 60 * 1000,           // Every 30 min
      
      // API port
      apiPort: 2468,
      
      // Logging
      logLevel: "info",
    };
  '';
in
{
  options.cg.service.cross-seed = {
    enable = lib.mkEnableOption "cross-seed for private tracker ratio building";

    port = lib.mkOption {
      type = lib.types.port;
      default = 2468;
      description = "Port for cross-seed web UI";
    };

    deployDefaultConfig = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Deploy default config.js template on first run";
    };
  };

  config = lib.mkIf cfg.enable {
    # Require media-stack and qbittorrent
    assertions = [
      {
        assertion = stack.enable;
        message = "cross-seed requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
      {
        assertion = qbt.enable;
        message = "cross-seed requires qbittorrent to be enabled (cg.service.qbittorrent.enable = true)";
      }
    ];

    # Create config directories
    systemd.tmpfiles.rules = [
      "d ${stack.configPath}/cross-seed 0775 ${stack.user} ${stack.group} -"
      "d ${stack.configPath}/cross-seed/output 0775 ${stack.user} ${stack.group} -"
    ];

    # Deploy config template on first run
    system.activationScripts.cross-seed-config = lib.mkIf cfg.deployDefaultConfig ''
      if [ ! -f "${stack.configPath}/cross-seed/config.js" ]; then
        echo "Deploying cross-seed config template..."
        cp ${crossSeedConfig} ${stack.configPath}/cross-seed/config.js
        chown ${stack.user}:${stack.group} ${stack.configPath}/cross-seed/config.js
        chmod 0640 ${stack.configPath}/cross-seed/config.js
        echo "Cross-seed config deployed to ${stack.configPath}/cross-seed/config.js"
        echo "IMPORTANT: Edit the config to add your Torznab URLs from Prowlarr!"
      fi
    '';

    # Container definition
    virtualisation.oci-containers.containers.cross-seed = {
      image = "ghcr.io/cross-seed/cross-seed:latest";
      user = "${toString config.users.users.${stack.user}.uid}:${toString config.users.groups.${stack.group}.gid}";
      volumes = [
        "${stack.configPath}/cross-seed:/config"
        "${stack.configPath}/qbittorrent/qBittorrent/BT_backup:/torrents:ro"
        "${stack.dataPath}:/data"
      ];
      environment = {
        TZ = config.time.timeZone;
      };
      cmd = [ "daemon" ];
      # Route through VPN if qBittorrent uses VPN
      dependsOn = lib.optionals qbt.vpn.enable [ "gluetun" ];
      extraOptions = [
        "--pull=newer"
      ] ++ (if qbt.vpn.enable then [
        "--network=container:gluetun"
      ] else [
        "--network=arr-network"
      ]);
    };

    # Add cross-seed port to gluetun if VPN enabled
    # This is handled by modifying gluetun's port list in qbittorrent.nix
    # For non-VPN mode, open firewall directly
    networking.firewall.allowedTCPPorts = lib.mkIf (!qbt.vpn.enable) [ cfg.port ];
  };
}
