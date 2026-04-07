# Unpackerr - Extracts archived releases for Sonarr/Radarr
#
# Some torrent releases come as RAR archives. Unpackerr monitors
# the download directory and extracts them so the *arr apps can import.
#
# ARCHITECTURE NOTE:
# When running on homelab02 (NAS), unpackerr needs to talk to Sonarr/Radarr
# on homelab01 via their FQDNs (over the network). When running on homelab01,
# it can use container hostnames directly.
#
# SOPS SECRETS REQUIRED:
# - media-stack/sonarr/api
# - media-stack/radarr/api
#
# MIGRATION NOTES (homelab02 NAS):
# Unpackerr MOVES to homelab02 alongside qBittorrent.
# - Extracts directly to local disk (fast)
# - Connects to Sonarr/Radarr via FQDN
{
  config,
  lib,
  ...
}:

let
  cfg = config.cg.service.unpackerr;
  stack = config.cg.service.media-stack;

  # Determine if we're on the storage server (homelab02) or compute server (homelab01)
  # On storage server: use FQDNs to reach Sonarr/Radarr on homelab01
  # On compute server: use container hostnames (both on same host)
  isStorageServer = stack.storage.type == "local" && stack.enable;

  sonarrUrl = if isStorageServer then "https://sonarr.gyarmathy.co" else "http://sonarr:8989";

  radarrUrl = if isStorageServer then "https://radarr.gyarmathy.co" else "http://radarr:7878";
in
{
  options.cg.service.unpackerr = {
    enable = lib.mkEnableOption "Archived release unpacker";
  };

  config = lib.mkIf cfg.enable {
    # Require media-stack infrastructure
    assertions = [
      {
        assertion = stack.enable;
        message = "unpackerr requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
    ];

    # Sops secrets for API keys
    sops.secrets = {
      "media-stack/sonarr/api" = { };
      "media-stack/radarr/api" = { };
    };

    # Generate environment file with API keys
    sops.templates."unpackerr-env" = {
      content = ''
        UN_SONARR_0_API_KEY=${config.sops.placeholder."media-stack/sonarr/api"}
        UN_RADARR_0_API_KEY=${config.sops.placeholder."media-stack/radarr/api"}
      '';
      owner = stack.user;
      group = stack.group;
      mode = "0400";
    };

    # Create config directory
    systemd.tmpfiles.rules = [
      "d ${stack.configPath}/unpackerr 0775 ${stack.user} ${stack.group} -"
    ];

    # Container definition
    virtualisation.oci-containers.containers.unpackerr = {
      image = "ghcr.io/unpackerr/unpackerr:latest";

      environment = {
        TZ = config.time.timeZone;
        PUID = toString config.users.users.${stack.user}.uid;
        PGID = toString config.users.groups.${stack.group}.gid;

        # Sonarr connection
        UN_SONARR_0_URL = sonarrUrl;
        UN_SONARR_0_PATHS_0 = "/data/downloads";

        # Radarr connection
        UN_RADARR_0_URL = radarrUrl;
        UN_RADARR_0_PATHS_0 = "/data/downloads";

        # Extraction settings
        UN_PARALLEL = "1";
        UN_FILE_MODE = "0644";
        UN_DIR_MODE = "0755";

        # Watch download folder, auto extract
        UN_FOLDER_0_PATH = "/data/downloads/complete";
        UN_FOLDER_0_MOVE_BACK = "true";
        UN_FOLDER_0_DELETE_FILES = "false";
        UN_FOLDER_0_DELETE_ORIGINAL = "false";
      };

      environmentFiles = [
        config.sops.templates."unpackerr-env".path
      ];

      volumes = [
        "${stack.dataPath}/downloads:/data/downloads"
      ];

      extraOptions = [
        "--pull=newer"
        "--network=arr-network"
      ];
    };

    # Ensure network exists before starting
    systemd.services.podman-unpackerr = {
      after = [ "podman-network-arr.service" ];
      requires = [ "podman-network-arr.service" ];
    };
  };
}
