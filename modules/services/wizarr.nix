# Wizarr - User invitation and onboarding for Jellyfin
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.cg.service.wizarr;
  configPath = "/srv/arr/wizarr";
in
{
  options.cg.service.wizarr.enable = lib.mkEnableOption "Wizarr user invitation system";

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${configPath} 0775 coryg media -"
      "d ${configPath}/database 0775 coryg media -"
    ];

    virtualisation.oci-containers.containers.wizarr = {
      image = "ghcr.io/wizarrrr/wizarr:latest";
      volumes = [
        "${configPath}/database:/data/database"
      ];
      environment = {
        TZ = config.time.timeZone;
        APP_URL = "http://invite.gyarmathy.co"; # Update reverse proxy set up
      };
      ports = [ "5690:5690" ];
      extraOptions = [
        "--pull=newer"
        "--network=arr-network"
        "--add-host=host.containers.internal:host-gateway"
      ];
    };

    networking.firewall.allowedTCPPorts = [ 5690 ];
  };
}
