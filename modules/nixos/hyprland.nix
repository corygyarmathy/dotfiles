# Hyprland compositor - NixOS configuration
{
  inputs,
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.hyprland;
in
{
  options.cg.hyprland.enable = lib.mkEnableOption "Hyprland compositor";

  config = lib.mkIf cfg.enable {
    programs.hyprland = {
      enable = true;
      xwayland.enable = true;
    };

    # Polkit is required for privilege escalation
    security.polkit.enable = true;

    # XDG portal for screen sharing, file picking, etc.
    xdg.portal = {
      enable = true;
      extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    };

    environment.systemPackages = with pkgs; [
      xdg-desktop-portal-hyprland
      egl-wayland
    ];
  };
}
