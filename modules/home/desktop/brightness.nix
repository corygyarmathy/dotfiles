# Brightness control utilities
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.brightness;
in
{
  options.cg.home.brightness.enable = lib.mkEnableOption "Brightness control utilities";

  config = lib.mkIf cfg.enable {
    # brightnessctl is the one brightness tool, after item 12 of
    # docs/plans/desktop-design.md: the media-key binds go through
    # swayosd-client (which uses brightnessctl under the hood), the bar's
    # backlight module and hypridle both use it already, and brillo - which
    # used to own the keys and could disagree with all of them - is gone.
    home.packages = [
      pkgs.brightnessctl # Backlight control (bar module, hypridle, swayosd)
    ];
  };
}
