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
    home.packages = with pkgs; [
      brillo # Backlight control (used in hyprland config)
      brightnessctl # Alternative brightness control
    ];
  };
}
