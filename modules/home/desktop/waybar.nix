# Waybar status bar
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.waybar;
in
{
  options.cg.home.waybar.enable = lib.mkEnableOption "Waybar status bar";

  config = lib.mkIf cfg.enable {
    xdg.enable = true;

    # Source external config files for portability
    # These files can be used standalone on non-NixOS systems
    xdg.configFile = {
      "waybar/style.css".source = ../../../configs/waybar/style.css;
      "waybar/rose-pine.css".source = ../../../configs/waybar/rose-pine.css;
      "waybar/config".source = ../../../configs/waybar/config.jsonc;
    };

    programs.waybar = {
      enable = true;
      # Note: We're using xdg.configFile above instead of the settings/style options
      # This keeps the config portable for non-NixOS systems
    };
  };
}
