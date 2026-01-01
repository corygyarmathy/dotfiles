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
    xdg.enable = true;
    xdg.configFile.nvim = {
      source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/git/dotfiles/pkgs/nvim";
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
      basedpyright # Python LSP
      nodePackages.bash-language-server # Bash LSP
      docker-compose-language-service # Docker Compose LSP
      dockerfile-language-server-nodejs # Dockerfile LSP
      gopls # Go LSP
      lua-language-server # Lua LSP
      marksman # Markdown LSP
      nixd # Nix LSP
      nodePackages.vscode-langservers-extracted # JSON, HTML, CSS, ESLint LSPs (includes jsonls)
      powershell-editor-services # PowerShell LSP
      nodePackages.yaml-language-server # YAML LSP
      taplo # TOML LSP

      # Formatters
      stylua # Lua formatter
      nixfmt-rfc-style # Nix formatter
      nodePackages.prettier # JS/TS/JSON/YAML/Markdown formatter
      black # Python formatter (alternative to ruff)
      gotools # godoc, goimports, callgraph, digraph, stringer or toolstash etc.
      shfmt # Shell script formatter
      prettier

      # Linters
      ruff # Python linter & formatter
      shellcheck # Shell script linter
      markdownlint-cli2 # Markdown linter
      hadolint # Dockerfile linter
      golangci-lint # Go linter
      pkgs-stable.sqlfluff # SQL linter # Temp stable channel - build failure 2026-01-01

      # DAP (Debug Adapters)
      delve # Go debugger
      # go-debug-adapter is already included with delve
      python312Packages.debugpy # Python debugger

      # Utilities
      imagemagick
      statix
    ];
  };
}
