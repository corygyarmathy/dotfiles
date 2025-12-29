# Spotify terminal client
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.cg.home.spotify-player;
in {
  options.cg.home.spotify-player.enable = lib.mkEnableOption "Spotify player";

  config = lib.mkIf cfg.enable {
    programs.spotify-player = {
      enable = true;
      settings = {
        theme = "rose-pine";
        playback_window_position = "Top";
        copy_command = {
          command = "wl-copy";
          args = [];
        };
        device = {
          audio_cache = true;
          normalization = true;
          autoplay = true;
        };
      };
      themes = [
        {
          name = "rose-pine";
          palette = {
            background = "#191724";
            foreground = "#1f1d2e";
            black = "#414868";
            red = "#f7768e";
            green = "#9ece6a";
            yellow = "#e0af68";
            blue = "#2ac3de";
            magenta = "#bb9af7";
            cyan = "#7dcfff";
            white = "#eee8d5";
            bright_black = "#24283b";
            bright_red = "#ff4499";
            bright_green = "#73daca";
            bright_yellow = "#657b83";
            bright_blue = "#839496";
            bright_magenta = "#ff007c";
            bright_cyan = "#93a1a1";
            bright_white = "#fdf6e3";
          };
        }
      ];
    };

    home.packages = with pkgs; [
      spotify-player
      alsa-lib
      libdbusmenu-gtk3
    ];
  };
}
