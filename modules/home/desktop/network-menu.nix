# Network menu - item 9 of docs/plans/desktop-design.md.
#
# The bar's network module opens it on left click (its format toggle stays on
# right, via format-alt-click) and SUPER+SHIFT+W opens the same menu from the
# keyboard - principle 2's two reachable surfaces, the same arrangement the
# project picker has. See packages/network-menu.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.network-menu;

  network-menu = pkgs.network-menu or (pkgs.callPackage ../../../packages/network-menu { });
in
{
  options.cg.home.network-menu.enable = lib.mkEnableOption "Wifi network menu";

  config = lib.mkIf cfg.enable {
    home.packages = [ network-menu ];
  };
}
