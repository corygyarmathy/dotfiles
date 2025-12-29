# Rofi application launcher
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.cg.home.rofi;
in {
  options.cg.home.rofi.enable = lib.mkEnableOption "Rofi launcher";

  config = lib.mkIf cfg.enable {
    xdg.configFile."rofi/userconfig".source = ../../../configs/rofi/config.rasi;

    xdg.dataFile."rofi/themes" = {
      source = ../../../configs/rofi/themes;
      recursive = true;
    };

    home.packages = [pkgs.rofi];
  };
}
