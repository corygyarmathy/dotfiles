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
    home.packages = with pkgs; [
      hyprsunset
    ];

  };
}
