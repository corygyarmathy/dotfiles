# Cleanuparr - Stalled Download Cleanup
# Automatically removes stalled, failed, or completed downloads
#
# SETUP AFTER DEPLOYMENT:
# 1. Access web UI at http://hostname:11011
# 2. Configure connections to Sonarr/Radarr and qBittorrent
# 3. Set cleanup rules:
#    - Remove stalled downloads after X hours
#    - Remove completed downloads after reaching seed ratio
#    - Handle failed imports
#
# RATIO-BASED CLEANUP:
# Configure to delete torrents after reaching positive seed ratio
# to avoid HnR strikes while reclaiming space.
# For private trackers, you may want longer retention.
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
        PUID = toString config.users.users.${stack.user}.uid;
        PGID = toString config.users.groups.${stack.group}.gid;
      };
      volumes = [
        "${stack.configPath}/cleanuparr:/config"
        "${stack.dataPath}/downloads:/downloads"
      ];
      ports = [ "${toString cfg.port}:${toString cfg.port}" ];
      extraOptions = [
        "--pull=newer"
        "--network=arr-network"
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
