# nvim.nix

{
  pkgs,
  lib,
  config,
  ...
}:
{

  options = {
    cg.home.nvim.enable = lib.mkEnableOption "enables nvim";
  };

  config = lib.mkIf config.cg.home.nvim.enable {
    # waybar config
    xdg.enable = true;
    # xdg.configHome = config.lib.file.mkOutOfStoreSymlink "$HOME/.config";
    xdg.configFile.nvim = {
      # Sourcing in this manner is required so that the symlink is read/write (not just read),
      # so plugins can be updated and configs changed without rebuilding the system
      source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/git/dotfiles/pkgs/nvim"; # Apparently sourcing the file this way works better with nvim? Not sure.
    };

    home.packages = with pkgs; [
      neovim
      ripgrep # Requirement for nvim
      gnumake # Requirement for nvim
      unzip # Requirement for nvim
      xclip # Requirement for nvim
      fd # Re: for nvim. # Alternative to find
      tree-sitter # Re: for nvim (tree sitter)
      nodePackages.npm # JS Node Package Manager # Requirement for nvim (mason plugin)
    ];
  };
}
