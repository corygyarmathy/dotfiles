# Udiskie - USB automounting service
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.udiskie;
in
{
  options.cg.home.udiskie.enable = lib.mkEnableOption "Udiskie USB automounting";

  config = lib.mkIf cfg.enable {
    services.udiskie = {
      enable = true;
      automount = true;
      notify = true;
      tray = "auto"; # Show tray icon when devices are mounted
      settings = {
        program_options = {
          udisks_version = 2;
        };
        icon_names = {
          media = [ "drive-removable-media" ];
          eject = [ "media-eject" ];
          unmount = [ "media-eject" ];
        };
      };
    };
  };
}
