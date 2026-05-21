# Bash shell configuration
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.bash;
in
{
  # Bash is always enabled (required for starship and other integrations)
  options.cg.home.bash.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Enable Bash configuration";
  };

  config = lib.mkIf cfg.enable {
    programs.bash = {
      enable = true;
      initExtra = ''
        # Ensure proper terminal state
        if [[ -n "$ZELLIJ" ]]; then
          stty sane 2>/dev/null
        fi

        # Yazi - ability to change the cwd when exiting Yazi
        function y() {
          local tmp="$(mktemp -t "yazi-cwd.XXXXXX")" cwd
          command yazi "$@" --cwd-file="$tmp"
          IFS= read -r -d \'\' cwd < "$tmp"
          [ "$cwd" != "$PWD" ] && [ -d "$cwd" ] && builtin cd -- "$cwd"
          command rm -f -- "$tmp"
        }
      '';
    };
  };
}
