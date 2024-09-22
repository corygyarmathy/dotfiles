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

    # TODO: create this referenced config file :)
    xdg.configFile."zellij/config.kdl" = {
      source = ./config.kdl;
    };
    home.packages = with pkgs; [
      zellij
      vimPlugins.zellij-nav-nvim
    ];
  };
}
