# Yazi terminal file explorer
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.yazi;

  # yazi-plugins = pkgs.fetchFromGitHub {
  #   owner = "yazi-rs";
  #   repo = "plugins";
  #   rev = "...";
  #   hash = "sha256-...";
  # };
in
{
  options.cg.home.yazi.enable = lib.mkEnableOption "Yazi file explorer";

  config = lib.mkIf cfg.enable {
    # xdg.configFile = {
    #   "yazi/yazi.toml".source = ../../../configs/yazi/yazi.toml;
    #   "yazi/keymap.toml".source = ../../../configs/yazi/keymap.toml;
    #   "yazi/theme.toml".source = ../../../configs/yazi/theme.toml;
    # };

    # plugins = {
    #   chmod = "${yazi-plugins}/chmod.yazi";
    #   full-border = "${yazi-plugins}/full-border.yazi";
    #   toggle-pane = "${yazi-plugins}/toggle-pane.yazi";
    #   starship = pkgs.fetchFromGitHub {
    #     owner = "Rolv-Apneseth";
    #     repo = "starship.yazi";
    #     rev = "...";
    #     sha256 = "sha256-...";
    #   };
    # };

    home.packages = with pkgs; [
      yazi # File explorer
      ffmpeg # Video thumbnails
      _7zz # 7-Zip
      poppler # PDF preview
      fd # File searching
      ripgrep # File content searching
      fzf # File subtree navigation
      zoxide # Historical directories navigation
      resvg # SVG preview
      imagemagick # Font, HEIC, JPEG XL preview
      wl-clipboard # Wayland clipboard support
    ];
  };
}
