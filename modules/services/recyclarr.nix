# Recyclarr - Sync TRaSH Guides to Sonarr/Radarr
# Uses pre-built templates from TRaSH Guides for comprehensive quality profiles
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.cg.service.recyclarr;
  configPath = "/srv/arr/recyclarr";

  # Config file using TRaSH Guide templates
  # Templates automatically include quality definitions, profiles, and custom formats
  # See: https://recyclarr.dev/wiki/yaml/config-reference/
  recyclarrConfigYaml = pkgs.writeText "recyclarr.yml" ''
    # yaml-language-server: $schema=https://raw.githubusercontent.com/recyclarr/recyclarr/master/schemas/config-schema.json

    sonarr:
      shows:
        base_url: http://sonarr:8989
        api_key: !env_var SONARR_API_KEY
        delete_old_custom_formats: true
        replace_existing_custom_formats: true

        include:
          # Quality definitions (pick one - series for live action, anime for anime)
          - template: sonarr-quality-definition-series

          # WEB-1080p for most TV shows
          - template: sonarr-v4-quality-profile-web-1080p
          - template: sonarr-v4-custom-formats-web-1080p

          # WEB-2160p for 4K TV shows (assign to shows you want in 4K)
          - template: sonarr-v4-quality-profile-web-2160p
          - template: sonarr-v4-custom-formats-web-2160p

          # Anime profile (uses different release groups/scoring)
          - template: sonarr-v4-quality-profile-anime
          - template: sonarr-v4-custom-formats-anime

    radarr:
      movies:
        base_url: http://radarr:7878
        api_key: !env_var RADARR_API_KEY
        delete_old_custom_formats: true
        replace_existing_custom_formats: true

        include:
          # Quality definitions
          - template: radarr-quality-definition-movie

          # HD Bluray + WEB for most movies (1080p)
          - template: radarr-quality-profile-hd-bluray-web
          - template: radarr-custom-formats-hd-bluray-web

          # UHD Bluray + WEB for movies you want in 4K
          - template: radarr-quality-profile-uhd-bluray-web
          - template: radarr-custom-formats-uhd-bluray-web

          # Anime movies
          - template: radarr-quality-profile-anime
          - template: radarr-custom-formats-anime
  '';
in
{
  options.cg.service.recyclarr.enable = lib.mkEnableOption "Recyclarr TRaSH Guide sync";

  config = lib.mkIf cfg.enable {
    # Sops secrets - these will be available as files
    sops.secrets."arr/sonarr/api" = { };
    sops.secrets."arr/radarr/api" = { };

    systemd.tmpfiles.rules = [
      "d ${configPath} 0775 coryg media -"
    ];

    virtualisation.oci-containers.containers.recyclarr = {
      image = "ghcr.io/recyclarr/recyclarr:latest";
      user = "${toString config.users.users.coryg.uid}:${toString config.users.groups.media.gid}";
      volumes = [
        "${configPath}:/config"
        "${recyclarrConfigYaml}:/config/recyclarr.yml:ro" # Mount directly from nix store
      ];
      environment = {
        TZ = config.time.timeZone;
        CRON_SCHEDULE = "@daily";
      };
      environmentFiles = [
        config.sops.templates."recyclarr-env".path
      ];
      extraOptions = [
        "--pull=newer"
        "--network=arr-network"
      ];
    };

    # Sops template to create environment file
    sops.templates."recyclarr-env" = {
      content = ''
        SONARR_API_KEY=${config.sops.placeholder."arr/sonarr/api"}
        RADARR_API_KEY=${config.sops.placeholder."arr/radarr/api"}
      '';
    };

    systemd.services.podman-recyclarr = {
      after = [ "podman-network-arr.service" ];
      requires = [ "podman-network-arr.service" ];
    };
  };
}
