# Neovim editor
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.nvim;

  gotoolsWithoutModernize = pkgs.symlinkJoin {
    name = "gotools-without-modernize";
    paths = [ pkgs.gotools ];
    postBuild = ''
      rm -f "$out/bin/modernize"
    '';
  };
in
{
  options.cg.home.nvim.enable = lib.mkEnableOption "Neovim editor";

  config = lib.mkIf cfg.enable {
    xdg.enable = true;

    # Symlink nvim config from configs directory
    # Using mkOutOfStoreSymlink for live editing
    xdg.configFile.nvim = {
      source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/git/dotfiles/configs/nvim";
    };

    home.packages = with pkgs; [
      neovim

      # Core requirements
      fzf
      ripgrep
      gnumake
      unzip
      xclip
      fd
      tree-sitter

      # LSP servers
      basedpyright
      bash-language-server
      docker-compose-language-service
      nodejs
      gopls
      lua-language-server
      marksman
      nixd
      vscode-langservers-extracted
      powershell-editor-services
      yaml-language-server
      taplo

      # Formatters
      stylua
      nixfmt-rfc-style
      prettier
      black
      # gotools
      # Temporary measures for https://github.com/NixOS/nixpkgs/issues/509480
      gotoolsWithoutModernize
      shfmt
      prettier

      # Linters
      ruff
      shellcheck
      markdownlint-cli2
      hadolint
      golangci-lint
      sqlfluff # SQL linter

      # DAP
      delve
      python312Packages.debugpy

      # Utilities
      imagemagick
      statix
    ];
  };
}
