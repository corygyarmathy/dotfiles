# Bluetooth menu - item 9 of docs/plans/desktop-design.md.
#
# The bar's bluetooth module opens it on left click. The menu owns
# connect/disconnect for known devices; pairing goes through blueman-manager,
# which the package carries. See packages/bluetooth-menu.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.bluetooth-menu;

  bluetooth-menu = pkgs.bluetooth-menu or (pkgs.callPackage ../../../packages/bluetooth-menu { });
in
{
  options.cg.home.bluetooth-menu.enable = lib.mkEnableOption "Bluetooth device menu";

  config = lib.mkIf cfg.enable {
    home.packages = [ bluetooth-menu ];
  };
}
