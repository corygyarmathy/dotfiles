# Jellyfin Media Server
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.cg.service.jellyfin;
in
{
  options.cg.service.jellyfin.enable = lib.mkEnableOption "Jellyfin service";

  config = lib.mkIf cfg.enable {

    services.jellyfin = {
      enable = true;
      openFirewall = true; # Opens port 8096
      # Data stored in /var/lib/jellyfin by default
    };

    # Grant Jellyfin access to media files
    users.users.jellyfin.extraGroups = [ "media" "render" "video" ];

    # Create media directories
    # Owned by coryg:media so both user and services can write
    # The 2775 sets the setgid bit so new files inherit the media group
    systemd.tmpfiles.rules = [
      "d /srv/media 2775 coryg media -"
      "d /srv/media/movies 2775 coryg media -"
      "d /srv/media/tv 2775 coryg media -"
      "d /srv/media/music 2775 coryg media -"
      "d /srv/media/downloads 2775 coryg media -"
      "d /srv/media/downloads/complete 2775 coryg media -"
      "d /srv/media/downloads/incomplete 2775 coryg media -"
    ];

    # Hardware transcoding support
    # Jellyfin will automatically use VA-API if available
    # The hardware.graphics config in default.nix provides the drivers
  };
}
