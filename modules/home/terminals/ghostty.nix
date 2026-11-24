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

      exec ghostty +new-window -e "$@"
    '';
  };

  unitName = "app-com.mitchellh.ghostty.service";
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

    # The long-lived instance every `ghostty +new-window` opens its window in
    # (configs/ghostty/config says why). Ghostty ships the unit and a D-Bus
    # activation file for it; starting it with the graphical session means
    # the first terminal after login is warm too. The same shape as
    # home-manager's `programs.ghostty.systemd`, which this module does not
    # use because it would also hand the config file to stylix's Ghostty
    # target and inject bash integration.
    xdg.configFile."systemd/user/${unitName}".source = "${pkgs.ghostty}/share/systemd/user/${unitName}";
    xdg.configFile."systemd/user/graphical-session.target.wants/${unitName}".source =
      "${pkgs.ghostty}/share/systemd/user/${unitName}";
    # keep-old: every terminal window lives in this one process, so
    # restarting it on a switch (a Ghostty bump changes ExecStart) would close
    # them all. A config change reloads it in place instead - the unit is
    # Type=notify-reload.
    xdg.configFile."systemd/user/${unitName}.d/overrides.conf".text = ''
      [Unit]
      X-SwitchMethod=keep-old
      X-Reload-Triggers=${config.xdg.configFile."ghostty/config".source}
    '';

    # Copy shaders directory if it exists
    xdg.configFile."ghostty/shaders" = {
      source = ../../../configs/ghostty/shaders;
      recursive = true;
    };
  };
}
