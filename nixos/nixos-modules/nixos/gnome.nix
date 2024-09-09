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
    # Enable the X11 windowing system.
    services.xserver.enable = true;

    # Enable the GNOME Desktop Environment.
    services.xserver.displayManager = {
      gdm.enable = true;
      gnome.enable = true;
    };

    # Handles desktop windows interactions between each other (e.g. screen sharing)
    xdg.portal.enable = true;
    xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
  };
}
