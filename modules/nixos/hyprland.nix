# Hyprland compositor - NixOS configuration
{
  inputs,
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.cg.hyprland;
in {
  options.cg.hyprland.enable = lib.mkEnableOption "Hyprland compositor";

  config = lib.mkIf cfg.enable {
    programs.hyprland = {
      enable = true;
      xwayland.enable = true;
      # Ensures you're using the most up-to-date package
      package = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
      # Make sure to also set the portal package, so that they are in sync
      portalPackage = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.xdg-desktop-portal-hyprland;
    };

    environment.sessionVariables = {
      # Required for Hyprland on Nvidia
      WLR_NO_HARDWARE_CURSORS = "1"; # If your cusor becomes inviseble
      NIXOS_OZONE_WL = "1"; # Hint Electron apps to use Wayland
      LIBVA_DRIVER_NAME = "nvidia";
      XDG_SESSION_TYPE = "wayland";
      GBM_BACKEND = "nvidia-drm";
    };

    security.polkit.enable = true;

    environment.systemPackages = with pkgs; [
      xdg-desktop-portal-hyprland
      egl-wayland
    ];
  };
}
