# Do not disturb, and a history - item 13 of docs/plans/desktop-design.md.
#
# Principle 3's off switch, surfaced: the custom/dnd bar module reads dunst's
# own state and toggles it on click (SUPER+N is the keyboard path), and its
# right click opens the history menu for notifications that were missed. The
# module changes shape rather than only colour when paused, so do-not-disturb
# cannot be left on silently. See packages/dnd.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.dnd;

  dnd = pkgs.dnd or (pkgs.callPackage ../../../packages/dnd { });
in
{
  options.cg.home.dnd.enable =
    lib.mkEnableOption "Do-not-disturb bar module and notification history";

  config = lib.mkIf cfg.enable {
    home.packages = [ dnd ];
  };
}
