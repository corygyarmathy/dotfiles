-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

local map = vim.keymap.set

-- Make page up and down centred
map("n", "<C-u>", "<C-u>zz", { desc = "Move up half page" })
map("n", "<C-d>", "<C-d>zz", { desc = "Move down half page" })
