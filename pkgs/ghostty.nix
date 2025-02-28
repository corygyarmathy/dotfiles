{
  lib,
  config,
  ...
}:
{

  options = {
    cg.home.ghostty.enable = lib.mkEnableOption "enables ghostty";
  };

  config = lib.mkIf config.cg.home.ghostty.enable {
    # Ghostty config (terminal editor)
    programs.ghostty = {
      enable = true;
      enableBashIntegration = true;
      settings = {
        background-opacity = 0.85;
        background-blur = true;
        # window-padding-x = 10;
      };
    };
  };
}
