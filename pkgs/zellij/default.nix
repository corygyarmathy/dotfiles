{
  lib,
  config,
  pkgs,
  ...
}:
{

  # TODO: this is a stub, needs to be filled out
  options = {
    cg.home.zellij.enable = lib.mkEnableOption "setting zellij hm settings";
  };

  config = lib.mkIf config.cg.home.zellij.enable {
    # Configure zellij
    xdg.enable = true;

    xdg.configFile."zellij/config.kdl" = {
      source = ./config.kdl;
    };
    xdg.configFile."zellij/layouts/default.kdl" = {
      source = ./default.kdl;
    };
    home.packages = with pkgs; [
      unstable-small.zellij
      vimPlugins.zellij-nav-nvim
    ];
  };
}
