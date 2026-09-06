# Power and session menu - item 8 of docs/plans/desktop-design.md.
#
# The bar's custom/power module and SUPER+Escape both reach the same menu:
# every action is keybound and every action that can be a pointer target is
# one, and neither path is the real one. See packages/power-menu for what it
# does and why it needs no confirmation.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.power-menu;

  power-menu = pkgs.power-menu or (pkgs.callPackage ../../../packages/power-menu { });
in
{
  options.cg.home.power-menu.enable = lib.mkEnableOption "Power and session menu";

  config = lib.mkIf cfg.enable {
    home.packages = [ power-menu ];
  };
}
