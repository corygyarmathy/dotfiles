# Maintainerr - Automated Media Library Maintenance
# Identifies stale, unwatched, or over-requested media and automates cleanup
# through configurable rules. Integrates with Jellyfin, Sonarr, Radarr, and Seerr.
#
# Think of it as the opposite of Seerr: where Seerr adds media to your library,
# Maintainerr removes media that's no longer being watched.
#
# FEATURES:
# - Rule-based media identification (unwatched duration, request age, file size, etc.)
# - "Leaving Soon" collections shown on Jellyfin home screen before deletion
# - Integration with Sonarr/Radarr for unmonitoring or full deletion
# - Integration with Seerr for cleaning up fulfilled requests
# - Manual inclusion/exclusion overrides for one-off items
#
# SETUP AFTER DEPLOYMENT:
# 1. Access web UI at http://hostname:6246
#
# 2. Connect Media Server (Settings -> Media Server):
#    - Select Jellyfin
#    - URL: http://host.containers.internal:8096
#    - API Key: From Jellyfin Dashboard -> API Keys
#    - Test connection and select libraries to monitor
#
# 3. Connect Seerr (Settings -> Seerr):
#    - URL: http://seerr:5055
#    - API Key: From Seerr Settings -> General
#    - Required for request-based rules and request cleanup
#
# 4. Connect Sonarr (Settings -> Sonarr):
#    - URL: http://sonarr:8989
#    - API Key: From Sonarr Settings -> General
#    - Required for TV show removal/unmonitoring
#
# 5. Connect Radarr (Settings -> Radarr):
#    - URL: http://radarr:7878
#    - API Key: From Radarr Settings -> General
#    - Required for movie removal/unmonitoring
#
# 6. Create Rules (Rules -> Add):
#    Example rule: "Movies unwatched for 180 days"
#      - Media type: Movies
#      - Condition: Jellyfin - Last watched > 180 days ago
#      - Action: Delete from disk (via Radarr)
#
#    Example rule: "TV shows finished and unwatched for 90 days"
#      - Media type: Shows
#      - Condition: Sonarr - Status = Ended
#      - AND: Jellyfin - Last watched > 90 days ago
#      - Action: Delete from disk (via Sonarr)
#
#    Start with conservative rules (longer durations, dry-run) and tighten
#    as you build confidence in the cleanup behaviour.
#
# 7. Optional - "Leaving Soon" Collection:
#    Rules can be configured with a grace period that creates a collection
#    visible on the Jellyfin home screen (e.g., "Leaving in 7 days").
#    This gives users a chance to watch content before it's removed.
#
# PLACEMENT DECISION:
# Maintainerr runs on homelab01 because it needs direct access to:
# - Jellyfin (native service on homelab01)
# - Sonarr, Radarr, Seerr (containers on homelab01's arr-network)
# It does NOT need direct access to media files on disk - all operations
# are performed through the *arr and Jellyfin APIs.
#
# NOTE ON DECLARATIVE CONFIG:
# Maintainerr stores its configuration in a SQLite database via the web UI.
# Full declarative configuration is not currently supported by upstream.
# Service connections and rules must be configured manually after deployment.
{
  config,
  lib,
  ...
}:

let
  cfg = config.cg.service.maintainerr;
  stack = config.cg.service.media-stack;
in
{
  # Contributes to config.cg.publish, so it declares it - see
  # modules/nixos/publish.nix.
  imports = [ ../../nixos/publish.nix ];

  options.cg.service.maintainerr = {
    enable = lib.mkEnableOption "Maintainerr media library maintenance";

    port = lib.mkOption {
      type = lib.types.port;
      default = 6246;
      description = "Port for Maintainerr web UI";
    };

    basePath = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "/maintainerr";
      description = "Base path for the web UI (for reverse proxy setups)";
    };
  };

  config = lib.mkIf cfg.enable {
    cg.publish.maintainerr = {
      port = cfg.port;
      # A collection scan walks the whole Jellyfin library through this UI,
      # which the admin profile's 300-per-10-minutes cuts off partway.
      rateLimitProfile = "none";
    };

    # Require media-stack infrastructure
    assertions = [
      {
        assertion = stack.enable;
        message = "maintainerr requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
    ];

    # Create config directory
    systemd.tmpfiles.rules = [
      "d ${stack.configPath}/maintainerr 0775 ${stack.user} ${stack.group} -"
    ];

    # Container definition
    virtualisation.oci-containers.containers.maintainerr = {
      image = "ghcr.io/maintainerr/maintainerr:latest";
      user = "${toString config.users.users.${stack.user}.uid}:${
        toString config.users.groups.${stack.group}.gid
      }";
      environment = {
        TZ = config.time.timeZone;
      }
      // lib.optionalAttrs (cfg.basePath != "") {
        BASE_PATH = cfg.basePath;
      };
      volumes = [
        "${stack.configPath}/maintainerr:/opt/data"
      ];
      ports = [ "${toString cfg.port}:6246" ];
      extraOptions = [
        "--pull=newer"
        "--network=arr-network"
        # Allow container to reach host services (Jellyfin runs natively on host)
        "--add-host=host.containers.internal:host-gateway"
        # No podman healthcheck here on purpose. Readiness is probed by
        # blackbox_exporter (cg.monitoring.httpProbes), which actually alerts;
        # a podman healthcheck only coloured `podman ps` and fed nothing.
        #
        # It also broke the nightly upgrade. Podman runs each healthcheck as a
        # transient systemd unit, and `podman healthcheck run` exits non-zero
        # while a container is still starting - podman itself treats that as
        # fine (health_status=starting, streak 0), but systemd records a failed
        # unit either way. When `system.autoUpgrade` takes the kernel-unchanged
        # path it does an in-unit `nixos-rebuild switch`, which restarts this
        # container and then sweeps for failed units; a healthcheck firing in
        # that window made switch-to-configuration exit 4 and failed the whole
        # upgrade after it had already succeeded.
      ];
    };

    # Ensure network exists before starting
    systemd.services.podman-maintainerr = {
      after = [ "podman-network-arr.service" ];
      requires = [ "podman-network-arr.service" ];
    };

    # Firewall
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
