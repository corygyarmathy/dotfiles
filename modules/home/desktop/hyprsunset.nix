# Hyprsunset blue light filter
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.cg.home.hyprsunset;
in {
  options.cg.home.hyprsunset.enable = lib.mkEnableOption "Hyprsunset blue light filter";

  config = lib.mkIf cfg.enable {
    xdg.configFile."hypr/hyprsunset.conf".source = ../../../configs/hyprsunset/hyprsunset.conf;

    home.packages = [pkgs.hyprsunset];
  };
}
