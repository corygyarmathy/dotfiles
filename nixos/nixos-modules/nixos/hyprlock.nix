{
  pkgs,
  lib,
  config,
  ...
}:
{
  # TODO: investigate splitting hyprlock, hypridle
  options = {
    cg.hyprlock.enable = lib.mkEnableOption "enables hyprlock and hypridle";
  };

  config = lib.mkIf config.cg.hyprlock.enable {

    security.pam.services.hyprlock = { }; # Enables Hyprlock
    environment.systemPackages = with pkgs; [
      hyprlock
      hypridle
    ];
  };
}
