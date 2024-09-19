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

        # use alt-arrow keys without prefix key to switch panes
        # bind -n m-left select-pane -l
        # bind -n m-right select-pane -r
        # bind -n m-up select-pane -u
        # bind -n m-down select-pane -d

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

        # Smart pane switching with awareness of Vim splits.
        # See: https://github.com/christoomey/vim-tmux-navigator

        # decide whether we're in a Vim process
        is_vim="ps -o state= -o comm= -t '#{pane_tty}' \
            | grep -iqE '^[^TXZ ]+ +(\\S+\\/)?g?(view|n?vim?x?)(diff)?$'"

        bind-key -n 'C-h' if-shell "$is_vim" 'send-keys C-h' 'select-pane -L'
        bind-key -n 'C-j' if-shell "$is_vim" 'send-keys C-j' 'select-pane -D'
        bind-key -n 'C-k' if-shell "$is_vim" 'send-keys C-k' 'select-pane -U'
        bind-key -n 'C-l' if-shell "$is_vim" 'send-keys C-l' 'select-pane -R'

        tmux_version='$(tmux -V | sed -En "s/^tmux ([0-9]+(.[0-9]+)?).*/\1/p")'

        if-shell -b '[ "$(echo "$tmux_version < 3.0" | bc)" = 1 ]' \
            "bind-key -n 'C-\\' if-shell \"$is_vim\" 'send-keys C-\\'  'select-pane -l'"
        if-shell -b '[ "$(echo "$tmux_version >= 3.0" | bc)" = 1 ]' \
            "bind-key -n 'C-\\' if-shell \"$is_vim\" 'send-keys C-\\\\'  'select-pane -l'"

        bind-key -n 'C-Space' if-shell "$is_vim" 'send-keys C-Space' 'select-pane -t:.+'

        bind-key -T copy-mode-vi 'C-h' select-pane -L
        bind-key -T copy-mode-vi 'C-j' select-pane -D
        bind-key -T copy-mode-vi 'C-k' select-pane -U
        bind-key -T copy-mode-vi 'C-l' select-pane -R
        bind-key -T copy-mode-vi 'C-\' select-pane -l
        # bind-key -T copy-mode-vi 'C-Space' select-pane -t:.+
      '';
    };
  };
}
