# Alacritty terminal emulator
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.cg.home.alacritty;
in {
  options.cg.home.alacritty.enable = lib.mkEnableOption "Alacritty terminal";

  config = lib.mkIf cfg.enable {
    programs.alacritty = {
      enable = true;
      settings = {
        window = {
          opacity = lib.mkForce 0.85;
          padding.x = 10;
        };
        env = {
          TERM = "xterm-256color"; # Enable 24-bit colour
        };
      };
    };
  };
}
