# Jellyfin Media Server
# Self-hosted media streaming server (open source Plex/Emby alternative)
#
# NOTE: This module uses the native NixOS Jellyfin service (not a container)
# for better hardware acceleration support with Intel Quick Sync.
#
# SETUP AFTER DEPLOYMENT:
# 1. Access web UI at http://hostname:8096
# 2. Create admin user during initial setup
# 3. Add media libraries:
#    - Movies: /srv/media/movies
#    - TV Shows: /srv/media/tv
#    - Music: /srv/media/music
# 4. Enable hardware transcoding in Dashboard -> Playback -> Transcoding:
#    - Hardware acceleration: Video Acceleration API (VA-API)
#    - VA-API Device: /dev/dri/renderD128
#
# MIGRATION NOTES (homelab02 NAS):
# Jellyfin stays on homelab01 (has Intel Quick Sync for transcoding).
# When NFS is enabled, the media paths will automatically point to NFS.
# Library paths remain the same (/srv/media/...), no reconfiguration needed.
#
# NOTE: Jellyfin is part of the media-stack for organizational purposes,
# but it's more loosely coupled than other services - it doesn't use the
# podman network and connects via host filesystem paths directly.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.cg.service.jellyfin;
  stack = config.cg.service.media-stack;
in
{
  options.cg.service.jellyfin = {
    enable = lib.mkEnableOption "Jellyfin media server";

    postProcessingMode = lib.mkOption {
      type = lib.types.enum [
        "chapters"
        "cut"
      ];
      default = "chapters";
      description = "Post-processing mode: chapters (mark commercials) or cut (remove commercials)";
    };
  };

  config = lib.mkIf cfg.enable {
    # Require media-stack infrastructure
    assertions = [
      {
        assertion = stack.enable;
        message = "jellyfin requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
    ];

    # Native NixOS Jellyfin service
    services.jellyfin = {
      enable = true;
      openFirewall = true; # Opens port 8096
    };

    # Open firewall for DLNA/uPnP and service discovery
    # Required for Google Cast and other network streaming devices
    networking.firewall = {
      allowedTCPPorts = [
        1900 # UPnP discovery
        7359 # Jellyfin client discovery
      ];
      allowedUDPPorts = [
        1900 # UPnP discovery
        5353 # mDNS (Bonjour/Avahi)
        7359 # Jellyfin client discovery
      ];

      # Allow multicast for service discovery
      # This is required for Cast devices to find Jellyfin
      extraCommands = ''
        iptables -A INPUT -p udp -d 224.0.0.0/4 -j ACCEPT
        iptables -A INPUT -p udp -d 239.255.255.250 -j ACCEPT
      '';
      extraStopCommands = ''
        iptables -D INPUT -p udp -d 224.0.0.0/4 -j ACCEPT || true
        iptables -D INPUT -p udp -d 239.255.255.250 -j ACCEPT || true
      '';
    };

    # Grant Jellyfin access to media files and hardware acceleration
    users.users.jellyfin.extraGroups = [
      stack.group # Media file access
      "render" # GPU access for transcoding
      "video" # Video device access
    ];

    # Prioritise Jellyfin for system resources
    # This is a media server - transcoding should be responsive
    systemd.services.jellyfin = {
      serviceConfig = {
        CPUWeight = 200;
        MemoryHigh = "8G";
        MemoryMax = "10G";
        IOWeight = 200;
        # Override upstream default UMask of 0077 (owner-only) to allow
        # media group read/write access. Required because Jellyfin writes
        # recordings and trickplay data to NFS-mounted media directories
        # that other services (Sonarr, Radarr) also need to access via
        # the shared 'media' group.
        UMask = lib.mkForce "0002";
      };
    };

    # Set post-processing script based on mode
    systemd.services.jellyfin.environment = {
      JELLYFIN_PublishedServerUrl = "https://jellyfin.gyarmathy.co";
    };

    cg.service = {
      # Enable recording stitcher
      jellyfin-recording-stitcher = {
        enable = true;
        recordingsPath = "/srv/media/livetv";
        stabilityDelay = 600; # 10 minutes
        graceDelay = 600; # 10 minutes
      };

      # Enable recording cleanup
      jellyfin-recording-cleanup = {
        enable = true;
        recordingsPath = "/srv/media/livetv";
        retentionDays = 14;
        schedule = "03:00"; # 3 AM daily
        cleanIntermediateFiles = true;
      };

      # Enable recording post-processor
      jellyfin-recording-post-processor = {
        enable = true;
        recordingsPath = "/srv/media/livetv";
        postProcessScript =
          if cfg.postProcessingMode == "cut" then
            "${pkgs.comskip-cut}/bin/post-process"
          else
            "${pkgs.comskip-chapters}/bin/post-process";
        schedule = "*:0/15";
      };
    };
  };
}
