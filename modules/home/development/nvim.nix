# Neovim editor
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.nvim;
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
      dockerfile-language-server-nodejs
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
      gotools
      shfmt
      prettier

      # Linters
      ruff
      shellcheck
      markdownlint-cli2
      hadolint
      golangci-lint
      # sqlfluff # SQL linter # Temp disable - build failure 2026-01-01

      # DAP
      delve
      python312Packages.debugpy

      # Utilities
      imagemagick
      statix
    ];
  };
}
