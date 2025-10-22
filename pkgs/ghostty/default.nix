{
  pkgs,
  lib,
  config,
  ...
}:
{

  options = {
    cg.home.ghostty.enable = lib.mkEnableOption "enables ghostty";
  };

  config = lib.mkIf config.cg.home.ghostty.enable {

    # Ghostty config
    xdg = {
      enable = true;
      # configFile."ghostty/config/config" = {
      #   source = ./config;
      # };
      configFile."ghostty/shaders/shader.glsl" = {
        source = ./cursor_blaze.glsl;
      };
    };
    # Ghostty config (terminal editor)
    programs.ghostty = {
      enable = true;
      # enableBashIntegration = true;
      settings = {
        background-opacity = 0.85;
        background-blur = true;
        custom-shader = "./shaders/shader.glsl";
        # window-padding-x = 10;
      };
    };
  };
  # home.packages = with pkgs; [
  #   ghostty
  # ];
}
