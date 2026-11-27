# What is running, and what has failed.
#
# The custom/failed-units bar module is quiet when every user and system
# unit is healthy and shows a marker when any has failed - the same pattern
# as custom/nixos-upgrade. Clicking it lists the failed units and opens the
# chosen one's journal in the terminal. The process half (a single
# consistent left click into btop on cpu, memory and temperature) is the bar
# modules' own; this is the other half. See
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
