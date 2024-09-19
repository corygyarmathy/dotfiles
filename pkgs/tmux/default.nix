{
  pkgs,
  lib,
  config,
  ...
}:
{

  options = {
    cg.home.tmux.enable = lib.mkEnableOption "enables tmux";
  };

  config = lib.mkIf config.cg.home.tmux.enable {
    # xdg.configFile."tmux/tmux.conf" = {
    #   source = ./tmux.conf; # Sourcing conf file for config
    # };
    # home.packages = with pkgs; [
    #   tmux # Terminal multiplexer
    # ];
    programs.tmux = {
      enable = true;
      baseIndex = 1;
      prefix = "C-space";
      mouse = true;

      plugins = with pkgs; [
        tmuxPlugins.better-mouse-mode
        tmuxPlugins.catppuccin
        tmuxPlugins.sensible
        tmuxPlugins.vim-tmux-navigator
      ];

      extraConfig = ''
        # Enable 24-bit colour range
        set -g default-terminal "tmux-256color"
        set -ag terminal-overrides ",xterm-256color:RGB"

        # Vim style pane selection
        bind h select-pane -L
        bind j select-pane -D 
        bind k select-pane -U
        bind l select-pane -r

        # use alt-arrow keys without prefix key to switch panes
        bind -n m-left select-pane -l
        bind -n m-right select-pane -r
        bind -n m-up select-pane -u
        bind -n m-down select-pane -d

        # shift arrow to switch windows
        bind -n s-left  previous-window
        bind -n s-right next-window

        # shift alt vim keys to switch windows
        bind -n m-h previous-window
        bind -n m-l next-window

        set -g @catppuccin_flavour 'mocha'

        # set vi-mode
        set-window-option -g mode-keys vi

        # keybindings
        bind-key -T copy-mode-vi v send-keys -X begin-selection
        bind-key -T copy-mode-vi C-v send-keys -X rectangle-toggle
        bind-key -T copy-mode-vi y send-keys -X copy-selection-and-cancel

        bind '"' split-window -v -c "#{pane_current_path}"
        bind % split-window -h -c "#{pane_current_path}"
      '';
    };
  };
}
