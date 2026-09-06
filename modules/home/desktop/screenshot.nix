# Screenshot suite - item 15 of docs/plans/desktop-design.md.
#
# The full set under Print with modifiers: region to clipboard (the common
# case, unchanged), region to file, active window, current monitor - with
# satty offered as an optional annotation step on the save modes, and
# hyprpicker on its own binding for colours. See packages/screenshot.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.screenshot;

  screenshot = pkgs.screenshot or (pkgs.callPackage ../../../packages/screenshot { });
in
{
  options.cg.home.screenshot.enable =
    lib.mkEnableOption "Screenshot suite (grimblast + satty + hyprpicker)";

  config = lib.mkIf cfg.enable {
    home.packages = [
      screenshot
      pkgs.hyprpicker # colour picker, bound alongside in binds.lua
    ];
  };
}
