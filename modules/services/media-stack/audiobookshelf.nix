# Audiobookshelf - Self-hosted Audiobook & Podcast Server
# Serves audiobook libraries with progress tracking, metadata fetching,
# and native mobile app support (iOS/Android).
#
# SETUP AFTER DEPLOYMENT:
# 1. Access web UI at http://hostname:13378
# 2. Create an admin account on first launch
# 3. Add a library pointing to:
#    - /srv/media/audiobooks    (for audiobooks)
#    - /srv/media/podcasts      (for podcasts, if desired)
# 4. Library type must be set to "Audiobook" or "Podcast" respectively
#
# DIRECTORY STRUCTURE (audiobooks):
#   /srv/media/audiobooks/
#     Author Name/
#       Book Title/
#         chapter01.mp3 (or single file.m4b)
#         cover.jpg     (optional)
#
# ARCHITECTURE:
# Uses the upstream NixOS module (services.audiobookshelf) rather than a container.
# Runs as a native systemd service with its own user. The audiobookshelf user is
# added to the media group so it can read files from the NFS-mounted media store.
{
  config,
  lib,
  ...
}:

let
  cfg = config.cg.service.audiobookshelf;
  stack = config.cg.service.media-stack;
in
{
  # Contributes to config.cg.publish, so it declares it - see
  # modules/nixos/publish.nix.
  imports = [ ../../nixos/publish.nix ];

  options.cg.service.audiobookshelf = {
    enable = lib.mkEnableOption "Audiobookshelf audiobook and podcast server";

    port = lib.mkOption {
      type = lib.types.port;
      default = 13378;
      description = "Port for Audiobookshelf web UI";
    };
  };

  config = lib.mkIf cfg.enable {
    cg.publish.audiobookshelf = {
      port = cfg.port;
      rateLimitProfile = "media"; # streams audio, chapter by chapter
    };

    # Require media-stack infrastructure
    assertions = [
      {
        assertion = stack.enable;
        message = "audiobookshelf requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
    ];

    # Use the upstream NixOS module
    services.audiobookshelf = {
      enable = true;
      port = cfg.port;
      host = "0.0.0.0";
    };

    # Add the audiobookshelf user to the media group so it can read library files
    users.users.audiobookshelf.extraGroups = [ stack.group ];

    # Firewall
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
