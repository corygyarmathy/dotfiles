return {
	"obsidian-nvim/obsidian.nvim",
	version = "*", -- recommended, use latest release instead of latest commit
	lazy = true,
	enable = true,
	ft = "markdown",
	-- Replace the above line with this if you only want to load obsidian.nvim for markdown files in your vault:
	-- event = {
	--   -- If you want to use the home shortcut '~' here you need to call 'vim.fn.expand'.
	--   -- E.g. "BufReadPre " .. vim.fn.expand "~" .. "/my-vault/**.md"
	--   "BufReadPre path/to/my-vault/**.md",
	--   "BufNewFile path/to/my-vault/**.md",
	-- },
	dependencies = {
		-- Required.
		-- "nvim-lua/plenary.nvim",

		-- see below for full list of optional dependencies 👇
	},
	---@module 'obsidian'
	---@type obsidian.config
	opts = {
		-- A list of workspace names, paths, and configuration overrides.
		-- If you use the Obsidian app, the 'path' of a workspace should generally be
		-- your vault root (where the `.obsidian` folder is located).
		-- When obsidian.nvim is loaded by your plugin man/ger, it will automatically set
		-- the workspace to the first workspace in the list whose `path` is a parent of the
		-- current markdown file being edited.
		-- workspaces = function()
		--   -- Different file paths depending on whether it's on Windows or not
		--   if vim.fn.has 'win32' == 1 and vim.fn.has 'wsl' == 0 then
		--     return {
		--       name = 'personal',
		--       path = 'C:\\Users\\coryg\\Documents\\personal-notes',
		--     }
		--   else
		--     return {
		--       name = 'personal',
		--       path = '~/git/personal-notes',
		--     }
		--   end
		-- end,
		workspaces = {
			{
				name = "personal",
				path = "~/git/personal-notes",
			},
		},
	},
}

-- The line beneath this is called `modeline`. See `:help modeline`
-- vim: ts=2 sts=2 sw=2 et
