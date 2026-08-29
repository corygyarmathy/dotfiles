# Wizarr - User Invitation System
# Manages user invitations for Jellyfin
#
# SETUP AFTER DEPLOYMENT:
# 1. Access web UI at http://hostname:5690
# 2. Connect to Jellyfin:
#    - URL: http://host.containers.internal:8096 (or http://hostname:8096)
#    - API key from Jellyfin Dashboard -> API Keys
# 3. Create invitation links for new users
# 4. Configure user defaults and permissions
#
# MIGRATION NOTES (homelab02 NAS):
# Wizarr stays on homelab01 alongside Jellyfin.
{
  config,
  lib,
  ...
}:

let
  cfg = config.cg.service.wizarr;
  stack = config.cg.service.media-stack;
in
{
  # Contributes to config.cg.publish, so it declares it - see
  # modules/nixos/publish.nix.
  imports = [ ../../nixos/publish.nix ];

  options.cg.service.wizarr = {
    enable = lib.mkEnableOption "Wizarr user invitation system";

    port = lib.mkOption {
      type = lib.types.port;
      default = 5690;
      description = "Port for Wizarr web UI";
    };
  };

  config = lib.mkIf cfg.enable {
    # `invite` is the link handed to a new user, so it is the hostname.
    cg.publish.wizarr = {
      subdomain = "invite";
      port = cfg.port;
    };

    # Require media-stack infrastructure
    assertions = [
      {
        assertion = stack.enable;
        message = "wizarr requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
    ];

    # Create config directory
    systemd.tmpfiles.rules = [
      "d ${stack.configPath}/wizarr 0775 ${stack.user} ${stack.group} -"
    ];

    # Container definition
    virtualisation.oci-containers.containers.wizarr = {
      image = "ghcr.io/wizarrrr/wizarr:latest";
      environment = {
        TZ = config.time.timeZone;
      };
      volumes = [
        "${stack.configPath}/wizarr:/data/database"
      ];
      ports = [ "${toString cfg.port}:5690" ];
      extraOptions = [
        "--pull=newer"
        "--network=arr-network"
        "--add-host=host.containers.internal:host-gateway"
      ];
    };

    # Ensure network exists before starting
    systemd.services.podman-wizarr = {
      after = [ "podman-network-arr.service" ];
      requires = [ "podman-network-arr.service" ];
    };

    # Firewall
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
