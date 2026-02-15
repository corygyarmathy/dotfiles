# Seerr (prev. Jellyseerr) - Media Request Management
# Allows users to request movies and TV shows
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
{
  config,
  lib,
  ...
}:

let
  cfg = config.cg.service.seerr;
  stack = config.cg.service.media-stack;
in
{
  options.cg.service.seerr = {
    enable = lib.mkEnableOption "Seerr request management";

    port = lib.mkOption {
      type = lib.types.port;
      default = 5055;
      description = "Port for Seerr web UI";
    };
  };

  config = lib.mkIf cfg.enable {
    # Require media-stack infrastructure
    assertions = [
      {
        assertion = stack.enable;
        message = "Seerr requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
    ];

    # Create config directory
    systemd.tmpfiles.rules = [
      "d ${stack.configPath}/seerr 0775 ${stack.user} ${stack.group} -"
    ];

    # Container definition
    virtualisation.oci-containers.containers.seerr = {
      image = "ghcr.io/seerr-team/seerr:latest";
      environment = {
        TZ = config.time.timeZone;
        LOG_LEVEL = "info";
      };
      volumes = [
        "${stack.configPath}/seerr:/app/config"
      ];
      ports = [ "${toString cfg.port}:5055" ];
      extraOptions = [
        "--init"
        "--pull=newer"
        "--network=arr-network"
        # Allow container to reach host services (like Jellyfin)
        "--add-host=host.containers.internal:host-gateway"
      ];
    };

    # Ensure network exists before starting
    systemd.services.podman-seerr = {
      after = [ "podman-network-arr.service" ];
      requires = [ "podman-network-arr.service" ];
    };

    # Firewall
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
