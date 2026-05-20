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

    systemd.user.services.waybar = {
      Unit = {
        Description = "Waybar";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.waybar}/bin/waybar";
        Restart = "on-failure";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    # Source external config files for portability
    # These files can be used standalone on non-NixOS systems
    xdg.configFile."waybar" = {
      source = ../../../configs/waybar;
      recursive = true;
    };

    programs.waybar = {
      enable = true;
      # Note: We're using xdg.configFile above instead of the settings/style options
      # This keeps the config portable for non-NixOS systems
    };
  };
}
