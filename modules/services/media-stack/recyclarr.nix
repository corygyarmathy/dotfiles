# Recyclarr - TRaSH Guides Sync
# Automatically syncs quality profiles and custom formats from TRaSH Guides
# to Sonarr and Radarr
#
# SETUP AFTER DEPLOYMENT:
# 1. No web UI - runs on a schedule (daily by default)
# 2. Add API keys to sops secrets:
#    - media-stack/sonarr/api
#    - media-stack/radarr/api
# 3. Config is managed via Nix (recyclarrConfig option)
# 4. Check logs: journalctl -u podman-recyclarr
#
# The default config includes:
# - Sonarr: WEB-1080p (alternative), WEB-2160p (alternative), and Anime profiles
# - Radarr: HD Bluray+WEB, UHD Bluray+WEB, and Anime profiles
#
# NOTE: Alternative profiles include lower quality fallbacks (720p, HDTV, etc.)
# so media that isn't available in the preferred quality will still be grabbed.
#
# CUSTOMIZATION:
# Override recyclarrConfig to customize profiles and formats.
# See: https://recyclarr.dev/wiki/yaml/config-reference/
#
# MIGRATION NOTES (homelab02 NAS):
# Recyclarr stays on homelab01 alongside Sonarr/Radarr.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.cg.service.recyclarr;
  stack = config.cg.service.media-stack;

  # Default TRaSH Guides configuration
  defaultConfig = ''
    # yaml-language-server: $schema=https://raw.githubusercontent.com/recyclarr/recyclarr/master/schemas/config-schema.json

    sonarr:
      shows:
        base_url: http://sonarr:8989
        api_key: !env_var SONARR_API_KEY
        delete_old_custom_formats: true
        replace_existing_custom_formats: true

        media_naming:
          series: jellyfin-tvdb
          season: default
          episodes:
            rename: true
            standard: default
            daily: default
            anime: default

        include:
          # Quality definitions
          - template: sonarr-quality-definition-series

          # WEB-1080p Alternative - includes lower quality fallbacks (720p, HDTV)
          # for older shows or less available content
          - template: sonarr-v4-quality-profile-web-1080p-alternative
          - template: sonarr-v4-custom-formats-web-1080p

          # WEB-2160p Alternative - includes lower quality fallbacks
          # Will grab 4K when available, but falls back to 1080p/720p if not
          - template: sonarr-v4-quality-profile-web-2160p-alternative
          - template: sonarr-v4-custom-formats-web-2160p

          # Anime profile
          - template: sonarr-v4-quality-profile-anime
          - template: sonarr-v4-custom-formats-anime

    radarr:
      movies:
        base_url: http://radarr:7878
        api_key: !env_var RADARR_API_KEY
        delete_old_custom_formats: true
        replace_existing_custom_formats: true

        media_naming:
          folder: jellyfin-tmdb
          movie:
            rename: true
            standard: jellyfin-tmdb


        include:
          # Quality definitions
          - template: radarr-quality-definition-movie

          # HD Bluray + WEB for most movies (1080p)
          - template: radarr-quality-profile-hd-bluray-web
          - template: radarr-custom-formats-hd-bluray-web

          # UHD Bluray + WEB for 4K movies
          - template: radarr-quality-profile-uhd-bluray-web
          - template: radarr-custom-formats-uhd-bluray-web

          # Anime movies
          - template: radarr-quality-profile-anime
          - template: radarr-custom-formats-anime
  '';
in
{
  options.cg.service.recyclarr = {
    enable = lib.mkEnableOption "Recyclarr TRaSH Guide sync";

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "@daily";
      description = "Cron schedule for syncing (see systemd.time for format)";
    };

    recyclarrConfig = lib.mkOption {
      type = lib.types.lines;
      default = defaultConfig;
      description = "Recyclarr YAML configuration content";
    };
  };

  config = lib.mkIf cfg.enable {
    # Require media-stack infrastructure
    assertions = [
      {
        assertion = stack.enable;
        message = "recyclarr requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
    ];

    # Sops secrets for API keys
    sops.secrets."media-stack/sonarr/api" = { };
    sops.secrets."media-stack/radarr/api" = { };

    # Create config directory
    systemd.tmpfiles.rules = [
      "d ${stack.configPath}/recyclarr 0775 ${stack.user} ${stack.group} -"
    ];

    # Sops template for environment file
    sops.templates."recyclarr-env" = {
      content = ''
        SONARR_API_KEY=${config.sops.placeholder."media-stack/sonarr/api"}
        RADARR_API_KEY=${config.sops.placeholder."media-stack/radarr/api"}
      '';
    };

    # Container definition
    virtualisation.oci-containers.containers.recyclarr = {
      image = "ghcr.io/recyclarr/recyclarr:latest";
      user = "${toString config.users.users.${stack.user}.uid}:${
        toString config.users.groups.${stack.group}.gid
      }";
      volumes = [
        "${stack.configPath}/recyclarr:/config"
        "${pkgs.writeText "recyclarr.yml" cfg.recyclarrConfig}:/config/recyclarr.yml:ro"
      ];
      environment = {
        TZ = config.time.timeZone;
        CRON_SCHEDULE = cfg.schedule;
      };
      environmentFiles = [
        config.sops.templates."recyclarr-env".path
      ];
      extraOptions = [
        "--pull=newer"
        "--network=arr-network"
      ];
    };

    # Ensure network exists before starting
    systemd.services.podman-recyclarr = {
      after = [ "podman-network-arr.service" ];
      requires = [ "podman-network-arr.service" ];
    };
  };
}
