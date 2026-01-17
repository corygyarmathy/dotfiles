# unpackerr.nix
{
  config,
  lib,
  ...
}:
let
  cfg = config.cg.service.media-stack;
  stack = config.cg.service.media-stack;
in
{
  options.cg.service.unpackerr = {
    enable = lib.mkEnableOption "Archived release unpacker";
  };

  config = lib.mkIf cfg.enable {
    virtualisation.oci-containers.containers.unpackerr = {
      image = "ghcr.io/unpackerr/unpackerr:latest";

      environment = {
        TZ = config.time.timeZone;
        PUID = toString config.users.users.${stack.user}.uid;
        PGID = toString config.users.groups.${stack.group}.gid;

        # Sonarr
        UN_SONARR_0_URL = "http://sonarr:8989";
        UN_SONARR_0_PATHS_0 = "${cfg.dataPath}/downloads";

        # Radarr
        UN_RADARR_0_URL = "http://radarr:7878";
        UN_RADARR_0_PATHS_0 = "${cfg.dataPath}/downloads";
      };

      # environmentFiles = [
      #   config.sops.secrets."unpackerr/env".path
      # ];

      volumes = [
        "${stack.dataPath}/downloads:/data/downloads"
      ];

      extraOptions = [
        "--network=media-stack"
      ];
    };
  };
}
