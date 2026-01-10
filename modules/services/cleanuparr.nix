# Cleanuparr - Clean up stalled/failed downloads
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.cg.service.cleanuparr;
  configPath = "/srv/arr/cleanuparr";
in
{
  options.cg.service.cleanuparr.enable = lib.mkEnableOption "Cleanuparr stalled download cleanup";

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${configPath} 0775 coryg media -"
    ];

    virtualisation.oci-containers.containers.cleanuparr = {
      image = "ghcr.io/cleanuparr/cleanuparr:latest";
      volumes = [
        "${configPath}:/config"
      ];
      environment = {
        TZ = config.time.timeZone;
      };
      ports = [ "5000:5000" ];
      extraOptions = [
        "--pull=newer"
        "--network=arr-network"
      ];
    };

    systemd.services.podman-cleanuparr = {
      after = [ "podman-network-arr.service" ];
      requires = [ "podman-network-arr.service" ];
    };

    networking.firewall.allowedTCPPorts = [ 5000 ];
  };
}
