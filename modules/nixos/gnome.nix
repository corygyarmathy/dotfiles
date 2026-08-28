# GNOME desktop environment
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.gnome;
in
{
  options.cg.gnome.enable = lib.mkEnableOption "GNOME desktop environment";

  config = lib.mkIf cfg.enable {
    services.xserver = {
      enable = true;
      displayManager.gdm.enable = true;
      desktopManager.gnome.enable = true;
    };

    # Handles desktop windows interactions between each other (e.g. screen sharing)
    xdg.portal.enable = true;
  };
}
