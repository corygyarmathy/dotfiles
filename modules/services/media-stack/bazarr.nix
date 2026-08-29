# Bazarr - Subtitle Management
# Automatically downloads subtitles for movies and TV shows
#
# SETUP AFTER DEPLOYMENT:
# 1. Access web UI at http://hostname:6767
# 2. Configure subtitle providers (OpenSubtitles, Subscene, etc.)
# 3. Connect to Sonarr: Settings -> Sonarr -> http://sonarr:8989
# 4. Connect to Radarr: Settings -> Radarr -> http://radarr:7878
# 5. Set languages and quality preferences
#
# MIGRATION NOTES (homelab02 NAS):
# Bazarr stays on homelab01. When NFS is enabled:
# - /data will point to NFS mount automatically
# - No other changes needed
{
  config,
  lib,
  ...
}:

let
  cfg = config.cg.service.bazarr;
  stack = config.cg.service.media-stack;
in
{
  # Contributes to config.cg.publish, so it declares it - see
  # modules/nixos/publish.nix.
  imports = [ ../../nixos/publish.nix ];

  options.cg.service.bazarr = {
    enable = lib.mkEnableOption "Bazarr subtitle management";

    port = lib.mkOption {
      type = lib.types.port;
      default = 6767;
      description = "Port for Bazarr web UI";
    };
  };

  config = lib.mkIf cfg.enable {
    # Published under its own name at the module's own port; whether it
    # answers from outside the LAN is the host's call.
    cg.publish.bazarr.port = cfg.port;

    # Require media-stack infrastructure
    assertions = [
      {
        assertion = stack.enable;
        message = "bazarr requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
    ];

    # Create config directory
    systemd.tmpfiles.rules = [
      "d ${stack.configPath}/bazarr 0775 ${stack.user} ${stack.group} -"
    ];

    # Container definition
    virtualisation.oci-containers.containers.bazarr = {
      image = "lscr.io/linuxserver/bazarr:latest";
      environment = {
        PUID = toString config.users.users.${stack.user}.uid;
        PGID = toString config.users.groups.${stack.group}.gid;
        TZ = config.time.timeZone;
      };
      volumes = [
        "${stack.configPath}/bazarr:/config"
        "${stack.dataPath}:/data"
      ];
      ports = [ "${toString cfg.port}:6767" ];
      extraOptions = [
        "--pull=newer"
        "--network=arr-network"
      ];
    };

    # Ensure network exists before starting
    systemd.services.podman-bazarr = {
      after = [ "podman-network-arr.service" ];
      requires = [ "podman-network-arr.service" ];
    };

    # Firewall
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
