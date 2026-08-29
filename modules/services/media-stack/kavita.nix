# Kavita - Unified Reading Server
# Self-hosted reading server for ebooks (EPUB/PDF), comics (CBZ/CBR), and manga
#
# SETUP AFTER DEPLOYMENT:
# 1. Access web UI at http://hostname:5000
# 2. Create an admin account on first launch
# 3. Add libraries pointing to:
#    - /srv/media/books    (for ebooks)
#    - /srv/media/comics   (for comics and manga)
# 4. Configure scanning schedule in Settings > Tasks
#
# ARCHITECTURE:
# Kavita uses the upstream NixOS module (services.kavita) rather than a container.
# It runs as a native systemd service with its own user, but we ensure the kavita
# user is added to the media group so it can read files written by containers.
#
# MIGRATION NOTES (homelab02 NAS):
# When NFS is enabled, the library paths remain the same - the underlying mount
# changes transparently via media-stack storage configuration.
{
  config,
  lib,
  ...
}:

let
  cfg = config.cg.service.kavita;
  stack = config.cg.service.media-stack;
in
{
  # Contributes to config.cg.publish, so it declares it - see
  # modules/nixos/publish.nix.
  imports = [ ../../nixos/publish.nix ];

  options.cg.service.kavita = {
    enable = lib.mkEnableOption "Kavita reading server";

    port = lib.mkOption {
      type = lib.types.port;
      default = 5000;
      description = "Port for Kavita web UI";
    };
  };

  config = lib.mkIf cfg.enable {
    cg.publish.kavita = {
      port = cfg.port;
      rateLimitProfile = "media"; # a reader: many small requests per page turn
    };

    # Require media-stack infrastructure
    assertions = [
      {
        assertion = stack.enable;
        message = "kavita requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
    ];

    sops.secrets."media-stack/kavita/token-key" = {
      owner = "kavita";
      group = "kavita";
    };

    # Use the upstream NixOS module
    services.kavita = {
      enable = true;
      settings.Port = cfg.port;
      tokenKeyFile = config.sops.secrets."media-stack/kavita/token-key".path;
    };

    # Add the kavita user to the media group so it can read library files
    users.users.kavita.extraGroups = [ stack.group ];

    # Firewall
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
