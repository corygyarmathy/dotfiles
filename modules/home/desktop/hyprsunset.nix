{
  pkgs,
  lib,
  config,
  ...
}:
{
  options = {
    cg.home.hyprsunset.enable = lib.mkEnableOption "enables hyprsunset";
  };

  config = lib.mkIf config.cg.home.hyprsunset.enable {
    # Hyprsunset config
    xdg.configFile."hypr/hyprsunset.conf" = {
      source = ./hyprsunset.conf;
    };
    home.packages = with pkgs; [
      hyprsunset
    ];

  };
}
