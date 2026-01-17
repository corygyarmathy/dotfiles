# Prowlarr - Indexer Manager
# Centralized indexer management for Sonarr, Radarr, and other *arr apps
# Syncs indexers to all connected applications automatically
#
# SETUP AFTER DEPLOYMENT:
# 1. Access web UI at http://hostname:9696
# 2. Add indexers (both public and private trackers)
# 3. Add FlareSolverr for Cloudflare-protected indexers:
#    Settings -> Indexers -> Add FlareSolverr -> http://flaresolverr:8191
# 4. Add applications (Sonarr, Radarr) in Settings -> Apps
#    - Sonarr: http://sonarr:8989
#    - Radarr: http://radarr:7878
#
# MIGRATION NOTES (homelab02 NAS):
# Prowlarr stays on homelab01. No changes needed for NAS migration.
{
  config,
  lib,
  ...
}:

let
  cfg = config.cg.service.prowlarr;
  stack = config.cg.service.media-stack;
in
{
  options.cg.service.prowlarr = {
    enable = lib.mkEnableOption "Prowlarr indexer manager";

    port = lib.mkOption {
      type = lib.types.port;
      default = 9696;
      description = "Port for Prowlarr web UI";
    };
  };

  config = lib.mkIf cfg.enable {
    # Require media-stack infrastructure
    assertions = [
      {
        assertion = stack.enable;
        message = "prowlarr requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
    ];

    # Create config directory
    systemd.tmpfiles.rules = [
      "d ${stack.configPath}/prowlarr 0775 ${stack.user} ${stack.group} -"
    ];

    # Container definition
    virtualisation.oci-containers.containers.prowlarr = {
      image = "lscr.io/linuxserver/prowlarr:latest";
      environment = {
        PUID = toString config.users.users.${stack.user}.uid;
        PGID = toString config.users.groups.${stack.group}.gid;
        TZ = config.time.timeZone;
      };
      volumes = [
        "${stack.configPath}/prowlarr:/config"
      ];
      ports = [ "${toString cfg.port}:9696" ];
      extraOptions = [
        "--pull=newer"
        "--network=arr-network"
      ];
    };

    # Ensure network exists before starting
    systemd.services.podman-prowlarr = {
      after = [ "podman-network-arr.service" ];
      requires = [ "podman-network-arr.service" ];
    };

    # Firewall
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
