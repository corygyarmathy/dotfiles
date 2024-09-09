{
  pkgs,
  lib,
  config,
  ...
}:
{

  options = {
    cg.gnome.enable = lib.mkEnableOption "enables gnome DE";
  };

  config = lib.mkIf config.cg.gnome.enable {
    # Enable the X11 windowing system, and GNOME desktop environment
    services.xserver = {
      enable = true;
      displayManager.gdm.enable = true;
      desktopManager.gnome.enable = true;
    };

    # Handles desktop windows interactions between each other (e.g. screen sharing)
    xdg.portal.enable = true;
    xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
  };
}
