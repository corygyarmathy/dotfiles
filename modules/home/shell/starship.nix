# Starship prompt
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.starship;
in
{
  options.cg.home.starship.enable = lib.mkEnableOption "Starship prompt";

  config = lib.mkIf cfg.enable {
    programs.starship = {
      enable = true;
      enableBashIntegration = true;
    };

    # Source external config for portability
    xdg.configFile."starship.toml".source = ../../../configs/starship/starship.toml;

    home.packages = [ pkgs.starship ];
  };
}
