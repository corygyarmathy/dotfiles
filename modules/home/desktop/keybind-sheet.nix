# Keybind sheet - item 11 of docs/plans/desktop-design.md.
#
# SUPER+slash opens the sheet, parsed live from the deployed binds.lua. The
# parse is gated at build time too - hyprland.nix runs the same parser over
# the checked-in file, so a binds.lua this stops understanding fails the
# build rather than silently losing its documentation. See
# packages/keybind-sheet.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.keybind-sheet;

  keybind-sheet = pkgs.keybind-sheet or (pkgs.callPackage ../../../packages/keybind-sheet { });
in
{
  options.cg.home.keybind-sheet.enable = lib.mkEnableOption "Keybind reference sheet";

  config = lib.mkIf cfg.enable {
    home.packages = [ keybind-sheet ];
  };
}
