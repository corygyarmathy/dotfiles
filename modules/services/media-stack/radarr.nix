# Radarr - Movie Management
# Automatically searches, downloads, and organizes movies
#
# SETUP AFTER DEPLOYMENT:
# 1. Access web UI at http://hostname:7878
# 2. Set Root Folder to: /data/movies
# 3. Add download client (qBittorrent at http://qbittorrent:8080 or http://gluetun:8080 if VPN)
# 4. Add indexers via Prowlarr sync
#
# HARDLINKS:
# This container mounts the entire dataPath as /data, enabling hardlinks
# between /data/downloads and /data/movies (same filesystem inside container).
#
# MIGRATION NOTES (homelab02 NAS):
# Radarr stays on homelab01. When NFS is enabled:
# - /data will point to NFS mount automatically
# - Download client URL changes to homelab02's qBittorrent
# - May need to update remote path mappings in download client settings
{
  config,
  lib,
  ...
}:

let
  cfg = config.cg.service.radarr;
  stack = config.cg.service.media-stack;
in
{
  options.cg.service.radarr = {
    enable = lib.mkEnableOption "Radarr movie management";

    port = lib.mkOption {
      type = lib.types.port;
      default = 7878;
      description = "Port for Radarr web UI";
    };
  };

  config = lib.mkIf cfg.enable {
    # Require media-stack infrastructure
    assertions = [
      {
        assertion = stack.enable;
        message = "radarr requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
    ];

    # Create config directory
    systemd.tmpfiles.rules = [
      "d ${stack.configPath}/radarr 0775 ${stack.user} ${stack.group} -"
    ];

    # Container definition
    virtualisation.oci-containers.containers.radarr = {
      image = "lscr.io/linuxserver/radarr:latest";
      environment = {
        PUID = toString config.users.users.${stack.user}.uid;
        PGID = toString config.users.groups.${stack.group}.gid;
        TZ = config.time.timeZone;
        UMASK = "002"; # produces 775 dirs / 664 files
      };
      volumes = [
        "${stack.configPath}/radarr:/config"
        "${stack.dataPath}:/data"
      ];
      ports = [ "${toString cfg.port}:7878" ];
      extraOptions = [
        "--pull=newer"
        "--network=arr-network"
      ];
    };

    # Ensure network exists before starting
    systemd.services.podman-radarr = {
      after = [ "podman-network-arr.service" ];
      requires = [ "podman-network-arr.service" ];
    };

    # Firewall
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
