-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- LSP options --
vim.g.lazyvim_python_lsp = "basedpyright"

-- Detect NixOS
vim.g.is_nixos = vim.fn.filereadable("/etc/NIXOS") == 1

-- vim-dadbod-ui: read connections from $DATABASE_URL instead of its $DBUI_URL
-- default, so any project whose direnv shell exports DATABASE_URL (the Go/Nix
-- convention) shows up in :DBUI with no per-project config.
vim.g.db_ui_env_variable_url = "DATABASE_URL"
