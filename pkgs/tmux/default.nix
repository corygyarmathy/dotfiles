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
    xdg.configFile."tmux/tmux.conf" = {
      source = ./tmux.conf; # Sourcing conf file for config
    };
    home.packages = with pkgs; [
      tmux # Terminal multiplexer
    ];
  };
}
