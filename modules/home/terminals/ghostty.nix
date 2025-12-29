# Ghostty terminal emulator
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.cg.home.ghostty;
in {
  options.cg.home.ghostty.enable = lib.mkEnableOption "Ghostty terminal";

  config = lib.mkIf cfg.enable {
    programs.ghostty = {
      enable = true;
      settings = {
        background-opacity = 0.85;
        background-blur = true;
        custom-shader = "./shaders/shader.glsl";
        keybind = [
          "ctrl+enter=unbind"
        ];
      };
    };
  };
}
