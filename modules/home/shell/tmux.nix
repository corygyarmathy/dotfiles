# Tmux terminal multiplexer
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.cg.home.tmux;
in
{
  options.cg.home.tmux.enable = lib.mkEnableOption "tmux terminal multiplexer";

  config = lib.mkIf cfg.enable {
    programs.tmux = {
      enable = true;
      baseIndex = 1;
      prefix = "C-space";
      mouse = true;
      tmuxinator.enable = true;

      plugins = with pkgs; [
        tmuxPlugins.better-mouse-mode
        tmuxPlugins.catppuccin
        tmuxPlugins.sensible
        tmuxPlugins.vim-tmux-navigator
        tmuxPlugins.resurrect # Resurrect old tmux sessions (e.g. after system restart)
        tmuxPlugins.continuum # Automatically save and load tmux sessions. Dep: tmuxPlugins.resurrect
      ];

      # Source the portable config file
      extraConfig = builtins.readFile ../../../configs/tmux/tmux.conf;
    };

    # Import tmuxinator projects / configs
    xdg.configFile."tmuxinator/" = {
      source = ../../../configs/tmux/tmuxinator;
      recursive = true;
    };
  };
}
