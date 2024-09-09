# nvim.nix

{
  pkgs,
  lib,
  config,
  ...
}:
{

  options = {
    cg.home.rofi.enable = lib.mkEnableOption "enables rofi";
  };

  config = lib.mkIf config.cg.home.rofi.enable {
    # Rofi config
    xdg.configFile."rofi/userconfig" = {
      source = ./config.rasi;
    };
    # Rofi themes
    xdg.dataFile."rofi/themes" = {
      source = ./themes;
      recursive = true;
    };

    home.packages = with pkgs; [
      rofi-wayland # Uplauncher for Wayland
    ];
  };
}
