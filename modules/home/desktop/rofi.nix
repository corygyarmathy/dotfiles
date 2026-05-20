# Rofi application launcher
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.rofi;
in
{
  options.cg.home.rofi.enable = lib.mkEnableOption "Rofi launcher";

  config = lib.mkIf cfg.enable {
    xdg.configFile."rofi" = {
      source = ../../../configs/rofi;
      recursive = true;
    };

    home.packages = [ pkgs.rofi ];
  };
}
