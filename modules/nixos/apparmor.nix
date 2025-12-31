# modules/nixos/apparmor.nix
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.apparmor;
in
{
  options.cg.apparmor.enable = lib.mkEnableOption "AppArmor mandatory access control";

  config = lib.mkIf cfg.enable {
    security.apparmor = {
      enable = true;
      killUnconfinedConfinables = false; # Don't kill apps, just warn
    };

    # Include common profiles
    environment.systemPackages = [ pkgs.apparmor-profiles ];
  };
}
