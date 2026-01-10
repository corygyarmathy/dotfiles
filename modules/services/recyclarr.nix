# Recyclarr - Sync TRaSH Guides to Sonarr/Radarr (Simplified)
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.cg.service.recyclarr;
  configPath = "/srv/arr/recyclarr";

  # Config file using environment variable substitution
  recyclarrConfigYaml = pkgs.writeText "recyclarr.yml" ''
    sonarr:
      main:
        base_url: http://sonarr:8989
        api_key: !env_var SONARR_API_KEY
        
        quality_definition:
          type: series
        
        quality_profiles:
          - name: WEB-1080p
            reset_unmatched_scores:
              enabled: true
            upgrade:
              allowed: true
              until_quality: WEB 1080p
              until_score: 10000
            min_format_score: 0
            quality_sort: top
            qualities:
              - name: WEB 1080p
                qualities:
                  - WEBDL-1080p
                  - WEBRip-1080p
              - name: HDTV-1080p
              - name: WEB 720p
                qualities:
                  - WEBDL-720p
                  - WEBRip-720p
              - name: HDTV-720p
        
        custom_formats:
          - trash_ids:
              - 85c61753df5da1fb2aab6f2a47426b09  # BR-DISK
              - 9c11cd3f07101571f917ea1df9270e9a  # LQ
              - e2315f990da7d706d4a0b9e8c3b09a51  # LQ (Release Title)
              - 47435ece6b99a0b477caf360e79ba0bb  # x265 (HD)
              - fbcb31d8dabd2a319072b84fc0b7249c  # Extras
            quality_profiles:
              - name: WEB-1080p
                score: -10000
          
          - trash_ids:
              - d660701077794679fd59e8bdf4ce3a29  # AMZN
              - f67c9ca88f463a48346062e8ad07713f  # ATVP
              - 36b72f59f4ea20aad9c8cfc0d45e5b73  # DSNP
              - 89358767a60cc28783cdc3d0be9388a4  # HMAX
              - 7a235133c87f7da4c8cccceb7f8dab5c  # HBO
              - a880d6abc21e7c16884f3ae393f84179  # HULU
              - d34870697c9db575f17700212167be23  # NF
              - 1656adc6d7bb2c8cca6acfb6592db421  # PCOK
              - c67a75ae4a1715f2bb4d492f4d56a22a  # PMTP
            quality_profiles:
              - name: WEB-1080p
                score: 100

    radarr:
      main:
        base_url: http://radarr:7878
        api_key: !env_var RADARR_API_KEY
        
        quality_definition:
          type: movie
        
        quality_profiles:
          - name: HD Bluray + WEB
            reset_unmatched_scores:
              enabled: true
            upgrade:
              allowed: true
              until_quality: Bluray-1080p
              until_score: 10000
            min_format_score: 0
            quality_sort: top
            qualities:
              - name: Bluray-1080p
              - name: WEB 1080p
                qualities:
                  - WEBDL-1080p
                  - WEBRip-1080p
              - name: Bluray-720p
              - name: WEB 720p
                qualities:
                  - WEBDL-720p
                  - WEBRip-720p
        
        custom_formats:
          - trash_ids:
              - 0f12c086e289cf966fa5948eac571f44  # Hybrid
              - 570bc9ebecd92723d2d21500f4be314c  # Remaster
              - eca37840c13c6ef2dd0262b141a5482f  # 4K Remaster
              - e0c07d59beb37348e975a930d5e50319  # Criterion Collection
              - 9d27d9d2181838f76dee150882bdc58c  # Masters of Cinema
              - db9b4c4b53d312a3ca5f1378f6440fc9  # Vinegar Syndrome
            quality_profiles:
              - name: HD Bluray + WEB
                score: 25
          
          - trash_ids:
              - ed38b889b31be83fda192888e2286d83  # BR-DISK
              - 90a6f9a284dff5103f6346090e6280c8  # LQ
              - dc98083864ea246d05a42df0d05f81cc  # x265 (HD)
              - b8cd450cbfa689c0259a01d9e29ba3d6  # 3D
            quality_profiles:
              - name: HD Bluray + WEB
                score: -10000
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
      # Symlink the config file from nix store
      "L+ ${configPath}/recyclarr.yml - - - - ${recyclarrConfigYaml}"
    ];

    virtualisation.oci-containers.containers.recyclarr = {
      image = "ghcr.io/recyclarr/recyclarr:latest";
      user = "${toString config.users.users.coryg.uid}:${toString config.users.groups.media.gid}";
      volumes = [
        "${configPath}:/config"
      ];
      environment = {
        TZ = config.time.timeZone;
        CRON_SCHEDULE = "@daily";
        # These get populated from sops via environmentFiles
      };
      environmentFiles = [
        # We need to create a file that exports these env vars
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
