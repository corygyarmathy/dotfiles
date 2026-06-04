return {
	{
		"obsidian-nvim/obsidian.nvim",
		version = "*",
		lazy = true,
		ft = "markdown",
		keys = {
			-- entry points (work from anywhere; they load the plugin + open notes)
			{ "<leader>oo", "<cmd>Obsidian quick_switch<cr>", desc = "Quick switch (open note)" },
			{ "<leader>os", "<cmd>Obsidian search<cr>", desc = "Search notes (grep)" },
			{ "<leader>on", "<cmd>Obsidian new_from_template<cr>", desc = "New note from template" },
			{ "<leader>oj", "<cmd>Obsidian today<cr>", desc = "Today's daily note" },
			{ "<leader>ot", "<cmd>Obsidian tags<cr>", desc = "Search tags" },
			{ "<leader>oT", "<cmd>Obsidian template<cr>", desc = "Insert template" },
			-- in-note commands
			{ "<leader>ob", "<cmd>Obsidian backlinks<cr>", desc = "Backlinks to this note" },
			{ "<leader>ol", "<cmd>Obsidian links<cr>", desc = "Links in this note" },
			{ "<leader>of", "<cmd>Obsidian follow_link<cr>", desc = "Follow link under cursor" },
			{ "<leader>or", "<cmd>Obsidian rename<cr>", desc = "Rename note (updates backlinks)" },
			{ "<leader>ox", "<cmd>Obsidian toggle_checkbox<cr>", desc = "Toggle checkbox" },
			{ "<leader>op", "<cmd>Obsidian paste_img<cr>", desc = "Paste image" },
		},
		---@module 'obsidian'
		---@type obsidian.config
		opts = {
			workspaces = { { name = "personal", path = "~/git/personal-notes" } },
			picker = { name = "snacks.pick" },
			attachments = { img_folder = "Files" },
			ui = { enable = false },

			-- keep your frontmatter, just don't add `id`
			frontmatter = {
				func = function(note)
					local out = { aliases = note.aliases, tags = note.tags }
					for k, v in pairs(note.metadata or {}) do
						out[k] = v -- preserve custom keys like `parent`
					end
					return out
				end,
				sort = { "aliases", "tags", "parent" },
			},

			templates = { folder = "Templates" },

			link = { style = "wiki", format = "shortest" },

			sync = {
				enabled = true,
				configs = {}, -- safe even if the desktop app is occasionally open on this machine
			},
		},
	},

	-- name the which-key group so <leader>o shows "obsidian"
	{
		"folke/which-key.nvim",
		opts = { spec = { { "<leader>o", group = "obsidian" } } },
	},
}
