# Mylar3 - Comic & Manga Automation
# Monitors comic series and automatically downloads new issues via torrent/usenet
#
# SETUP AFTER DEPLOYMENT:
# 1. Access web UI at http://hostname:8090
# 2. Configure ComicVine API key in Settings > Web Interface > API
# 3. Add download client (qBittorrent at http://qbittorrent:8080 or http://gluetun:8080 if VPN)
# 4. Set Comic Library Location to: /data/comics
# 5. Set download directory to: /data/downloads/complete
# 6. Add series to monitor and set issues as 'wanted'
#
# HARDLINKS:
# This container mounts the entire dataPath as /data, enabling hardlinks
# between /data/downloads and /data/comics (same filesystem inside container).
#
# KAVITA INTEGRATION:
# Mylar3 downloads and organises comics into /data/comics which Kavita
# monitors as a library. Mylar3 can write ComicInfo.xml metadata into CBZ
# files, which Kavita reads for series/volume/issue metadata.
#
# MIGRATION NOTES (homelab02 NAS):
# Mylar3 stays on homelab01. When NFS is enabled:
# - /data will point to NFS mount automatically
# - Download client URL changes to homelab02's qBittorrent
{
  config,
  lib,
  ...
}:

let
  cfg = config.cg.service.mylar3;
  stack = config.cg.service.media-stack;
in
{
  options.cg.service.mylar3 = {
    enable = lib.mkEnableOption "Mylar3 comic and manga automation";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8090;
      description = "Port for Mylar3 web UI";
    };
  };

  config = lib.mkIf cfg.enable {
    # Require media-stack infrastructure
    assertions = [
      {
        assertion = stack.enable;
        message = "mylar3 requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
    ];

    # Create config directory
    systemd.tmpfiles.rules = [
      "d ${stack.configPath}/mylar3 0775 ${stack.user} ${stack.group} -"
    ];

    # Container definition
    virtualisation.oci-containers.containers.mylar3 = {
      image = "lscr.io/linuxserver/mylar3:latest";
      environment = {
        PUID = toString config.users.users.${stack.user}.uid;
        PGID = toString config.users.groups.${stack.group}.gid;
        TZ = config.time.timeZone;
        UMASK = "002"; # produces 775 dirs / 664 files
      };
      volumes = [
        "${stack.configPath}/mylar3:/config"
        "${stack.dataPath}:/data"
      ];
      ports = [ "${toString cfg.port}:8090" ];
      extraOptions = [
        "--pull=newer"
        "--network=arr-network"
      ];
    };

    # Ensure network exists before starting
    systemd.services.podman-mylar3 = {
      after = [ "podman-network-arr.service" ];
      requires = [ "podman-network-arr.service" ];
    };

    # Firewall
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
