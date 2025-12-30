# Hyprsunset blue light filter
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.hyprsunset;
in
{
  options.cg.home.hyprsunset.enable = lib.mkEnableOption "Hyprsunset blue light filter";

  config = lib.mkIf cfg.enable {
    # Source the config file
    xdg.configFile."hypr/hyprsunset.conf".source = ../../../configs/hyprsunset/hyprsunset.conf;

    home.packages = [ pkgs.hyprsunset ];

    # Run hyprsunset as a systemd user service
    systemd.user.services.hyprsunset = {
      Unit = {
        Description = "Hyprsunset blue light filter";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.hyprsunset}/bin/hyprsunset";
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
    };
  };
}
