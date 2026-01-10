# Recyclarr - Sync TRaSH Guides to Sonarr/Radarr
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.cg.service.recyclarr;
  configPath = "/srv/arr/recyclarr";
in
{
  options.cg.service.recyclarr.enable = lib.mkEnableOption "Recyclarr TRaSH Guide sync";

  config = lib.mkIf cfg.enable {
    # Config directory
    systemd.tmpfiles.rules = [
      "d ${configPath} 0775 coryg media -"
    ];

    virtualisation.oci-containers.containers.recyclarr = {
      image = "ghcr.io/recyclarr/recyclarr:latest";
      user = "${toString config.users.users.coryg.uid}:${toString config.users.groups.media.gid}";
      volumes = [
        "${configPath}:/config"
      ];
      environment = {
        TZ = config.time.timeZone;
        CRON_SCHEDULE = "@daily"; # Runs once daily
      };
      extraOptions = [
        "--pull=newer"
        "--network=arr-network"
      ];
    };

    # Ensure arr-network exists first
    systemd.services.podman-recyclarr = {
      after = [ "podman-network-arr.service" ];
      requires = [ "podman-network-arr.service" ];
    };
  };
}
