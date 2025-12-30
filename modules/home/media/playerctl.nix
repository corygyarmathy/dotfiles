# Playerctl - Media player control
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.playerctl;
in
{
  options.cg.home.playerctl.enable = lib.mkEnableOption "Playerctl media controls";

  config = lib.mkIf cfg.enable {
    services.playerctld.enable = true;

    home.packages = with pkgs; [
      playerctl
    ];
  };
}
