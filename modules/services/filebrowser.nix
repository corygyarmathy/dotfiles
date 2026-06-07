# File Browser - Web-based File Manager
# Provides drag-and-drop file upload/download via a web UI
#
# SETUP AFTER DEPLOYMENT:
# 1. Access web UI at http://hostname:8085
# 2. Default credentials: admin / admin (change immediately!)
# 3. The root directory is set to the media-stack data path,
#    giving access to /books, /comics, /downloads, etc.
#
# ARCHITECTURE:
# File Browser uses the upstream NixOS module (services.filebrowser)
# rather than a container. It runs as a native systemd service under
# the media-stack user/group, so it has direct read/write access to
# the same files that the *arr containers and Kavita use.
#
# USE CASES:
# - Upload manually downloaded manga/comics/books from your laptop
# - Browse and organise library files without SSH
# - Quick access to download directories for troubleshooting
#
# WARNING:
# File Browser has its own authentication. If exposed via Cloudflare
# Tunnel / Caddy, consider restricting access with Cloudflare Access
# policies or Caddy's basicauth, since File Browser grants full
# read/write to the media-stack data directory.
{
  config,
  lib,
  ...
}:

let
  cfg = config.cg.service.filebrowser;
  stack = config.cg.service.media-stack;
in
{
  options.cg.service.filebrowser = {
    enable = lib.mkEnableOption "File Browser web file manager";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8085;
      description = "Port for File Browser web UI";
    };
  };

  config = lib.mkIf cfg.enable {
    # Require media-stack infrastructure
    assertions = [
      {
        assertion = stack.enable;
        message = "filebrowser requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
    ];

    # The upstream services.filebrowser module emits a tmpfiles rule to ensure
    # settings.root exists, hardcoded to 0700. Because root is the shared pool
    # (/srv/media), that 0700 reasserts on every `nixos-rebuild switch` and
    # locks the media group (jellyfin, kavita, *arr) out of traversing it.
    # Force the mode to match nas-storage's 2775 instead of overriding it.
    systemd.tmpfiles.settings.filebrowser."${stack.dataPath}".d.mode = lib.mkForce "2775";

    # Use the upstream NixOS module
    services.filebrowser = {
      enable = true;

      # Run as the media-stack user/group so file permissions align
      # with the *arr containers and Kavita
      user = stack.user;
      group = stack.group;

      openFirewall = true;

      settings = {
        # Serve the entire media-stack data directory as the root
        # This gives access to /books, /comics, /downloads, etc.
        root = stack.dataPath;
        port = cfg.port;
        address = "0.0.0.0";
        database = "/var/lib/filebrowser/filebrowser.db";
      };
    };

    # Firewall (openFirewall above handles this, but being explicit
    # for consistency with other media-stack modules)
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
