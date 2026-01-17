# Jellyseerr - Media Request Management
# Allows users to request movies and TV shows (Overseerr fork for Jellyfin)
#
# SETUP AFTER DEPLOYMENT:
# 1. Access web UI at http://hostname:5055
# 2. Connect to Jellyfin:
#    - URL: http://host.containers.internal:8096 (or http://hostname:8096)
#    - Sign in with Jellyfin admin account
# 3. Connect to Sonarr:
#    - URL: http://sonarr:8989
#    - API key from Sonarr Settings -> General
# 4. Connect to Radarr:
#    - URL: http://radarr:7878
#    - API key from Radarr Settings -> General
# 5. Configure user permissions and notifications
#
# MIGRATION NOTES (homelab02 NAS):
# Jellyseerr stays on homelab01. No changes needed for NAS migration.
{
  config,
  lib,
  ...
}:

let
  cfg = config.cg.service.jellyseerr;
  stack = config.cg.service.media-stack;
in
{
  options.cg.service.jellyseerr = {
    enable = lib.mkEnableOption "Jellyseerr request management";

    port = lib.mkOption {
      type = lib.types.port;
      default = 5055;
      description = "Port for Jellyseerr web UI";
    };
  };

  config = lib.mkIf cfg.enable {
    # Require media-stack infrastructure
    assertions = [
      {
        assertion = stack.enable;
        message = "jellyseerr requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
    ];

    # Create config directory
    systemd.tmpfiles.rules = [
      "d ${stack.configPath}/jellyseerr 0775 ${stack.user} ${stack.group} -"
    ];

    # Container definition
    virtualisation.oci-containers.containers.jellyseerr = {
      image = "fallenbagel/jellyseerr:latest";
      environment = {
        TZ = config.time.timeZone;
        LOG_LEVEL = "info";
      };
      volumes = [
        "${stack.configPath}/jellyseerr:/app/config"
      ];
      ports = [ "${toString cfg.port}:5055" ];
      extraOptions = [
        "--pull=newer"
        "--network=arr-network"
        # Allow container to reach host services (like Jellyfin)
        "--add-host=host.containers.internal:host-gateway"
      ];
    };

    # Ensure network exists before starting
    systemd.services.podman-jellyseerr = {
      after = [ "podman-network-arr.service" ];
      requires = [ "podman-network-arr.service" ];
    };

    # Firewall
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
