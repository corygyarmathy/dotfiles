# nvim.nix

{
  pkgs,
  lib,
  config,
  ...
}:
{

  options = {
    spotify-player.enable = lib.mkEnableOption "enables spotify-player";
  };

  config = lib.mkIf config.spotify-player.enable {
    # Spotify player settings
    # TODO: split into separate module
    programs.spotify-player = {
      settings = {
        theme = "rose-pine";
        playback_window_position = "Top";
        copy_command = {
          command = "wl-copy";
          args = [ ];
        };
        device = {
          audio_cache = true; # Caches to $APP_CACHE ($HOME/.cache/...)
          normalization = true; # Enables audio normalisation between songs
          autoplay = true; # Autoplays similar songs
        };
      };
      themes = {
        # TODO: change colours to rose-pine, currently tokyo-night
        name = "rose-pine";
        pallette = {
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
      };
    };

    home.packages = with pkgs; [
      spotify-player # Spotify terminal client
      alsa-lib # Linux Sound library # Req for spotify-player
      libdbusmenu-gtk3 # Library for passing menu structures across DBus # Req for spotify-player
    ];
  };
}
