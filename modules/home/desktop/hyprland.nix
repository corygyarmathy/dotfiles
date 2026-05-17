# Hyprland - Home-manager configuration
# Updated for Hyprland 0.55+ (Lua config)
{
  inputs,
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.hyprland;
in
{
  options.cg.home.hyprland.enable = lib.mkEnableOption "Hyprland home configuration";

  config = lib.mkIf cfg.enable {
    # Deploy the Lua config files to ~/.config/hypr/
    # Hyprland 0.55+ loads hyprland.lua instead of hyprland.conf
    xdg.configFile = {
      "hypr/hyprland.lua".source = ../../../configs/hypr/hyprland.lua;
      "hypr/env.lua".source = ../../../configs/hypr/env.lua;
      "hypr/monitors.lua".source = ../../../configs/hypr/monitors.lua;
      "hypr/settings.lua".source = ../../../configs/hypr/settings.lua;
      "hypr/animations.lua".source = ../../../configs/hypr/animations.lua;
      "hypr/rules.lua".source = ../../../configs/hypr/rules.lua;
      "hypr/binds.lua".source = ../../../configs/hypr/binds.lua;
      "hypr/autostart.lua".source = ../../../configs/hypr/autostart.lua;
    };

    wayland.windowManager.hyprland = {
      enable = true;
      systemd = {
        enable = true;
        variables = [ "--all" ]; # Import all env vars including PATH
      };
    };

    home.packages = with pkgs; [
      # Screenshots
      grim # Screenshot utility
      slurp # Region selection
      wl-clipboard # Clipboard support
      grimblast # Helper for Hyprland screenshots

      # Hypr Utils
      hyprsysteminfo # System info util
    ];
  };
}
