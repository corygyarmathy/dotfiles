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
    # NOTE: I want to use Zellj on the next release (after v0.40.1)
    # as it adds a lot of the features I would like, and fixes many
    # existing bugs with the current release.
    xdg.configFile."zellij/config.kdl" = {
      source = ./config.kdl;
    };
    home.packages = with pkgs; [
      unstable-small.zellij
      vimPlugins.zellij-nav-nvim
    ];
  };
}
