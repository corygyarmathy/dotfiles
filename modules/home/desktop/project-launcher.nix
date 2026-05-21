# Home-manager module for project-launcher.
#
# Mirrors the structure of cg.home.waybar.media: a single enable flag plus
# the option surface a user might want to tweak per-host (scan directories,
# pinned monitor descriptor).
#
# The Hyprland keybind, the waybar custom module definition, and the CSS
# styling live in their respective config files (binds.lua, config.jsonc,
# style.css). This module is only responsible for putting the binary on PATH
# and exporting the runtime configuration as environment variables, so the
# config files don't need to bake user-specific paths.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.project-launcher;

  project-launcher =
    pkgs.project-launcher or (pkgs.callPackage ../../../packages/project-launcher { });
in
{
  options.cg.home.project-launcher = {
    enable = lib.mkEnableOption "Project workspace launcher for Hyprland";

    directories = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "~/Projects"
        "~/git"
      ];
      example = [
        "~/Projects"
        "~/work"
      ];
      description = ''
        Directories to scan for projects. Each immediate subdirectory of a
        listed path becomes a selectable project. Leading ~ is expanded to
        the user's home directory. Missing directories are silently skipped.
      '';
    };

    monitor = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "desc:Dell Inc. DELL U3419W 1Y9Q5T2";
      description = ''
        Monitor descriptor (as accepted by hyprctl) to pin new project
        workspaces to. When null, project workspaces open on whichever
        monitor is focused when the launcher is invoked.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ project-launcher ];

    # Export configuration via environment variables. systemd user services
    # (notably waybar) pick these up at session start, and so does any
    # process spawned from a graphical login.
    home.sessionVariables =
      {
        PROJECT_LAUNCHER_DIRS = lib.concatStringsSep ":" cfg.directories;
      }
      // lib.optionalAttrs (cfg.monitor != null) {
        PROJECT_LAUNCHER_MONITOR = cfg.monitor;
      };
  };
}
