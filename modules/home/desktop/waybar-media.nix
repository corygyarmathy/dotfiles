# Optional Waybar integration for now playing status
#
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.waybar.media;

  # Import the package
  waybar-media = pkgs.waybar-media or (pkgs.callPackage ../../../packages/waybar-media { });

in
{
  options.cg.home.waybar.media = {
    enable = lib.mkEnableOption "Now playing status module in waybar";
  };

  config = lib.mkIf cfg.enable {
    # Add the scripts to path
    home.packages = [ waybar-media ];
  };
}
