# Sonarr - TV Show Management
# Automatically searches, downloads, and organizes TV series
#
# SETUP AFTER DEPLOYMENT:
# 1. Access web UI at http://hostname:8989
# 2. Set Root Folder to: /data/tv
# 3. Add download client (qBittorrent at http://qbittorrent:8080 or http://gluetun:8080 if VPN)
# 4. Add indexers via Prowlarr sync
#
# HARDLINKS:
# This container mounts the entire dataPath as /data, enabling hardlinks
# between /data/downloads and /data/tv (same filesystem inside container).
#
# MIGRATION NOTES (homelab02 NAS):
# Sonarr stays on homelab01. When NFS is enabled:
# - /data will point to NFS mount automatically
# - Download client URL changes to homelab02's qBittorrent
# - May need to update remote path mappings in download client settings
{
  config,
  lib,
  ...
}:

let
  cfg = config.cg.service.sonarr;
  stack = config.cg.service.media-stack;
in
{
  options.cg.service.sonarr = {
    enable = lib.mkEnableOption "Sonarr TV show management";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8989;
      description = "Port for Sonarr web UI";
    };
  };

  config = lib.mkIf cfg.enable {
    # Require media-stack infrastructure
    assertions = [
      {
        assertion = stack.enable;
        message = "sonarr requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
    ];

    # Create config directory
    systemd.tmpfiles.rules = [
      "d ${stack.configPath}/sonarr 0775 ${stack.user} ${stack.group} -"
    ];

    # Container definition
    virtualisation.oci-containers.containers.sonarr = {
      image = "lscr.io/linuxserver/sonarr:latest";
      environment = {
        PUID = toString config.users.users.${stack.user}.uid;
        PGID = toString config.users.groups.${stack.group}.gid;
        TZ = config.time.timeZone;
        UMASK = "002"; # produces 775 dirs / 664 files
      };
      volumes = [
        "${stack.configPath}/sonarr:/config"
        "${stack.dataPath}:/data"
      ];
      ports = [ "${toString cfg.port}:8989" ];
      extraOptions = [
        "--pull=newer"
        "--network=arr-network"
      ];
    };

    # Ensure network exists before starting
    systemd.services.podman-sonarr = {
      after = [ "podman-network-arr.service" ];
      requires = [ "podman-network-arr.service" ];
    };

    # Firewall
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
