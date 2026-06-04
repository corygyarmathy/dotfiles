return {
	"obsidian-nvim/obsidian.nvim",
	version = "*", -- recommended, use latest release instead of latest commit
	lazy = true,
	enable = true,
	ft = "markdown",
	opts = {
		---@module 'obsidian'
		---@type obsidian.config

		workspaces = {
			{
				name = "personal",
				path = "~/git/personal-notes",
			},
		},

		attachments = {
			img_folder = "Files",
		},
		-- Handled by markdown-render
		ui = { enable = false },
	},
	keys = {
		{
			"<leader>p",
			"<cmd>Obsidian paste_img<cr>",
			desc = "Paste image in markdown",
		},
	},
}

-- The line beneath this is called `modeline`. See `:help modeline`
-- vim: ts=2 sts=2 sw=2 et
