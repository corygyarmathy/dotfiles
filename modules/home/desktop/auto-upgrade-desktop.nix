# modules/home/desktop/auto-upgrade-desktop.nix
#
# Desktop half of the upgrade module: the waybar indicator's package and styles.
#
# This used to also run a user service that watched a JSON state file and
# raised notifications when it changed. Both are gone: there is no state file
# any more (the indicator reads systemd and the store directly), and the click
# handler raises its own notifications for the actions the user actually takes.
# A background build failing shows on the bar rather than interrupting.
#
# Requires cg.auto-upgrade in the NixOS config, which provides the units this
# talks to.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.auto-upgrade-desktop;

  upgradeScripts = pkgs.callPackage ../../../packages/nixos-upgrade-scripts { };
in
{
  options.cg.home.auto-upgrade-desktop = {
    enable = lib.mkEnableOption "Desktop upgrade indicator (waybar)";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      upgradeScripts
      pkgs.libnotify
    ];

    xdg.configFile."waybar/nixos-upgrade.css" = lib.mkForce {
      source = ../../../configs/waybar/nixos-upgrade.css;
    };
  };
}
