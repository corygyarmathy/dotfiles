# What is running, and what has failed - item 14 of docs/plans/desktop-design.md.
#
# The custom/failed-units bar module is quiet when every user and system
# unit is healthy and shows a marker when any has failed - the same pattern
# as custom/nixos-upgrade. Clicking it lists the failed units and opens the
# chosen one's journal in the terminal. The process half of the item (a
# single consistent left click into btop on cpu, memory and temperature) was
# already built as item 3; this is the half that was not. See
# packages/failed-units.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.failed-units;

  failed-units = pkgs.failed-units or (pkgs.callPackage ../../../packages/failed-units { });
in
{
  options.cg.home.failed-units.enable =
    lib.mkEnableOption "Failed systemd units bar module and journal menu";

  config = lib.mkIf cfg.enable {
    home.packages = [ failed-units ];
  };
}
