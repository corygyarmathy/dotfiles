# Huntarr - Automatic search for missing and upgradeable media
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.cg.service.huntarr;
  configPath = "/srv/arr/huntarr";
in
{
  options.cg.service.huntarr.enable = lib.mkEnableOption "Huntarr missing media search";

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${configPath} 0775 coryg media -"
    ];

    # Sops secrets for API keys
    sops.secrets."arr/sonarr-api-key" = { };
    sops.secrets."arr/radarr-api-key" = { };

    virtualisation.oci-containers.containers.huntarr = {
      image = "huntarr/huntarr:latest";
      volumes = [
        "${configPath}:/config"
      ];
      environment = {
        TZ = config.time.timeZone;
      };
      ports = [ "9705:9705" ];
      extraOptions = [
        "--pull=newer"
        "--network=arr-network"
      ];
    };

    systemd.services.podman-huntarr = {
      after = [ "podman-network-arr.service" ];
      requires = [ "podman-network-arr.service" ];
    };

    networking.firewall.allowedTCPPorts = [ 9705 ];
  };
}
