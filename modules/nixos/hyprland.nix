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
      withUWSM = true;
    };

    # Polkit is required for privilege escalation
    security.polkit.enable = true;

    # XDG portal for screen sharing, file picking, etc.
    xdg.portal = {
      enable = true;
      extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    };

    # Minimal greeter — restarts on compositor crash
    services.greetd = {
      enable = true;
      settings = {
        default_session = {
          command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --sessions ${config.services.displayManager.sessionData.desktops}/share/wayland-sessions";
          user = "greeter";
        };
      };
    };

    # Suppress the default getty on TTY1 so greetd owns it cleanly
    systemd.services.greetd.serviceConfig = {
      Type = "idle"; # wait for boot to settle before showing the greeter
      StandardInput = "tty";
      StandardOutput = "tty";
      StandardError = "journal";
      TTYReset = true;
      TTYVHangup = true;
      TTYVTDisallocate = true;
    };

    environment.systemPackages = with pkgs; [
      xdg-desktop-portal-hyprland
      egl-wayland
      tuigreet
    ];
  };
}
