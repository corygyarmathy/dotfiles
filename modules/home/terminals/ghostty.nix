# Ghostty terminal emulator
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.ghostty;
in
{
  options.cg.home.ghostty.enable = lib.mkEnableOption "Ghostty terminal";

  config = lib.mkIf cfg.enable {
    programs.ghostty.enable = true;

    # Source portable config file
    # This file can be used standalone on non-NixOS systems
    xdg.configFile."ghostty/config".source = ../../../configs/ghostty/config;

    # Copy shaders directory if it exists
    xdg.configFile."ghostty/shaders" = {
      source = ../../../configs/ghostty/shaders;
      recursive = true;
    };
  };
}
