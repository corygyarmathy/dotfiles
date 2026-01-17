# Huntarr - Missing Media Search
# Automatically searches for missing and upgradeable media
#
# SETUP AFTER DEPLOYMENT:
# 1. Access web UI at http://hostname:9705
# 2. Add Sonarr connection:
#    - URL: http://sonarr:8989
#    - API key from Sonarr Settings -> General
# 3. Add Radarr connection:
#    - URL: http://radarr:7878
#    - API key from Radarr Settings -> General
# 4. Configure search schedules and criteria
#
# This complements the built-in search in Sonarr/Radarr by providing
# more aggressive/configurable searching for missing content.
#
# MIGRATION NOTES (homelab02 NAS):
# Huntarr stays on homelab01 alongside Sonarr/Radarr.
{
  config,
  lib,
  ...
}:

let
  cfg = config.cg.service.huntarr;
  stack = config.cg.service.media-stack;
in
{
  options.cg.service.huntarr = {
    enable = lib.mkEnableOption "Huntarr missing media search";

    port = lib.mkOption {
      type = lib.types.port;
      default = 9705;
      description = "Port for Huntarr web UI";
    };
  };

  config = lib.mkIf cfg.enable {
    # Require media-stack infrastructure
    assertions = [
      {
        assertion = stack.enable;
        message = "huntarr requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
    ];

    # Create config directory
    systemd.tmpfiles.rules = [
      "d ${stack.configPath}/huntarr 0775 ${stack.user} ${stack.group} -"
    ];

    # Container definition
    virtualisation.oci-containers.containers.huntarr = {
      image = "huntarr/huntarr:latest";
      environment = {
        TZ = config.time.timeZone;
      };
      volumes = [
        "${stack.configPath}/huntarr:/config"
      ];
      ports = [ "${toString cfg.port}:9705" ];
      extraOptions = [
        "--pull=newer"
        "--network=arr-network"
      ];
    };

    # Ensure network exists before starting
    systemd.services.podman-huntarr = {
      after = [ "podman-network-arr.service" ];
      requires = [ "podman-network-arr.service" ];
    };

    # Firewall
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
