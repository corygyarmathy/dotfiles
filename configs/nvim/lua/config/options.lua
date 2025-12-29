-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- LSP options --
vim.g.lazyvim_python_lsp = "basedpyright"

-- Detect NixOS
vim.g.is_nixos = vim.fn.filereadable("/etc/NIXOS") == 1
