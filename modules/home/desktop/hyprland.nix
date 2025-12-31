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

  # Startup script - kept in Nix because it needs package paths
  startupScript = pkgs.writeShellScriptBin "hyprland-startup" ''
    # Update DBus environment for screen sharing, etc.
    dbus-update-activation-environment --systemd HYPRLAND_INSTANCE_SIGNATURE
    dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
  '';
in
{
  options.cg.home.hyprland.enable = lib.mkEnableOption "Hyprland home configuration";

  config = lib.mkIf cfg.enable {
    # Source the portable config file
    xdg.configFile."hypr/hyprland.conf".source = ../../../configs/hypr/hyprland.conf;

    wayland.windowManager.hyprland = {
      enable = true;
      xwayland.enable = true;
      systemd.enable = true;

      # Minimal Nix config - just the startup that needs package paths
      # Everything else is in the portable hyprland.conf
      extraConfig = ''
        # Startup script (requires Nix package paths)
        exec-once = ${startupScript}/bin/hyprland-startup

        # Source the main config
        source = ~/.config/hypr/hyprland.conf
      '';
    };

    home.packages = with pkgs; [
      # Wallpaper
      swww # is this needed?

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
