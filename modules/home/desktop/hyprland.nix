# Hyprland - Home-manager configuration
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
    # Source the portable config file
    xdg.configFile."hypr/custom.conf".source = ../../../configs/hypr/hyprland.conf;

    wayland.windowManager.hyprland = {
      enable = true;
      systemd = {
        enable = true;
        variables = [ "--all" ]; # Import all env vars including PATH
      };

      # Source the main config
      extraConfig = ''
        source = ~/.config/hypr/custom.conf
      '';
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
