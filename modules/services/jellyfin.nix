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
  options.cg.jellyfin.enable = lib.mkEnableOption "Jellyfin service";

  config = lib.mkIf cfg.enable {

    services.jellyfin = {
      enable = true;
      openFirewall = true; # Opens port 8096
      # Data stored in /var/lib/jellyfin by default
    };

    # Grant Jellyfin access to media files
    users.users.jellyfin.extraGroups = [ "media" ];

    # Create media directories
    # These will be owned by root:media with group write permissions
    systemd.tmpfiles.rules = [
      "d /srv/media 0775 root media -"
      "d /srv/media/movies 0775 root media -"
      "d /srv/media/tv 0775 root media -"
      "d /srv/media/music 0775 root media -"
      "d /srv/media/downloads 0775 root media -"
      "d /srv/media/downloads/complete 0775 root media -"
      "d /srv/media/downloads/incomplete 0775 root media -"
    ];

    # Hardware transcoding support
    # Jellyfin will automatically use VA-API if available
    # The hardware.graphics config in default.nix provides the drivers
  };
}
