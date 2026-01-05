# Optional Waybar integration for DDC brightness status
#
# This adds a brightness indicator to your waybar that shows:
# - Current auto-brightness level
# - Click to adjust
# - Visual feedback for manual override status
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.waybar.ddc;

  # Import the package
  ddcBrightnessScripts =
    pkgs.ddc-brightness-scripts or (pkgs.callPackage ../../../packages/ddc-brightness-scripts { });

in
{
  options.cg.home.waybar.ddc = {
    enable = lib.mkEnableOption "DDC brightness indicator in waybar";
  };

  config = lib.mkIf cfg.enable {
    # Add the scripts to path
    home.packages = [ ddcBrightnessScripts ];

    # Add waybar module configuration
    # This should be merged with your existing waybar config

    # Add CSS for the brightness indicator
    xdg.configFile."waybar/ddc.css" = lib.mkForce {
      source = ../../../configs/waybar/ddc.css;
    };
  };
}
