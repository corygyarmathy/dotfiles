# FlareSolverr - Cloudflare Bypass Proxy
# Helps Prowlarr access indexers protected by Cloudflare
#
# SETUP AFTER DEPLOYMENT:
# 1. No web UI - runs as a headless service
# 2. Configure in Prowlarr:
#    Settings -> Indexers -> Add -> FlareSolverr
#    URL: http://flaresolverr:8191
# 3. Then for individual indexers that need it:
#    Edit indexer -> Tags -> Add FlareSolverr tag
#
# MIGRATION NOTES (homelab02 NAS):
# FlareSolverr stays on homelab01 alongside Prowlarr.
{
  config,
  lib,
  ...
}:

let
  cfg = config.cg.service.flaresolverr;
  stack = config.cg.service.media-stack;
in
{
  options.cg.service.flaresolverr = {
    enable = lib.mkEnableOption "FlareSolverr Cloudflare bypass";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8191;
      description = "Port for FlareSolverr API";
    };
  };

  config = lib.mkIf cfg.enable {
    # Require media-stack infrastructure
    assertions = [
      {
        assertion = stack.enable;
        message = "flaresolverr requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
    ];

    # Create config directory
    systemd.tmpfiles.rules = [
      "d ${stack.configPath}/flaresolverr 0775 ${stack.user} ${stack.group} -"
    ];

    # Container definition
    virtualisation.oci-containers.containers.flaresolverr = {
      image = "ghcr.io/flaresolverr/flaresolverr:latest";
      environment = {
        LOG_LEVEL = "info";
        LOG_HTML = "false";
        CAPTCHA_SOLVER = "none";
        TZ = config.time.timeZone;
      };
      ports = [ "${toString cfg.port}:8191" ];
      extraOptions = [
        "--pull=newer"
        "--network=arr-network"
      ];
    };

    # Ensure network exists before starting
    systemd.services.podman-flaresolverr = {
      after = [ "podman-network-arr.service" ];
      requires = [ "podman-network-arr.service" ];
    };

    # Firewall
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
