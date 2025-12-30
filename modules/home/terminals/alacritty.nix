# Alacritty terminal emulator
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.alacritty;
in
{
  options.cg.home.alacritty.enable = lib.mkEnableOption "Alacritty terminal";

  config = lib.mkIf cfg.enable {
    programs.alacritty.enable = true;

    # Source portable config file
    # This file can be used standalone on non-NixOS systems
    xdg.configFile."alacritty/alacritty.toml".source = ../../../configs/alacritty/alacritty.toml;
  };
}
