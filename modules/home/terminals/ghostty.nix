# Ghostty terminal emulator
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.ghostty;

  # `term-run <command> [args...]` - open a command in a terminal window.
  #
  # Item 3 of docs/plans/desktop-design.md: the terminal was named five times
  # in configs/waybar/config.jsonc, and it was still named `foot`. Which
  # terminal this desktop uses is decided here, so anything that needs to show
  # a TUI can shell out without restating the answer - and changing the
  # terminal is one edit rather than a search.
  termRun = pkgs.writeShellApplication {
    name = "term-run";
    runtimeInputs = [ pkgs.ghostty ];
    text = ''
      if [ "$#" -eq 0 ]; then
        echo "usage: term-run <command> [args...]" >&2
        exit 64
      fi

      exec ghostty -e "$@"
    '';
  };
in
{
  options.cg.home.ghostty.enable = lib.mkEnableOption "Ghostty terminal";

  config = lib.mkIf cfg.enable {
    home.packages = [
      pkgs.ghostty
      termRun
    ];

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
