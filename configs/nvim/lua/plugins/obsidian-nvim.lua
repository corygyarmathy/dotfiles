-- Name new notes after their title instead of a Zettelkasten id, so `[[Note Name]]`
-- creates `Note Name.md`. Used for every note that goes through `Note.create`
-- (link creation, `Obsidian new`, `Obsidian new_from_template`); daily notes and
-- `Obsidian unique_note` pass their own ids verbatim and are unaffected.
local function title_to_filename(title, dir)
	if type(title) ~= "string" then
		return require("obsidian.builtin").zettel_id()
	end

	-- Keep the title readable, just drop what Obsidian disallows in filenames.
	-- A "Folder/Note Name" input is still fine: obsidian.nvim splits the folder
	-- off before this runs, so only the last segment ever gets here.
	local name = title:gsub('[/\\*"<>:|?]', ""):gsub("%s+", " ")
	name = vim.trim(name):gsub("%.+$", "")

	if name == "" then
		return require("obsidian.builtin").zettel_id()
	elseif not dir then
		return name
	end

	-- Don't silently write into an existing note of the same name.
	local base_dir = require("obsidian.path").new(dir)
	local candidate, idx = name, 2
	while (base_dir / candidate):with_suffix(".md", true):exists() do
		candidate = string.format("%s %d", name, idx)
		idx = idx + 1
	end

	return candidate
end

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
			{
				"<leader>og",
				function()
					local vault = vim.fn.expand("~/git/personal-notes")
					local res = vim.system(
						{ "python3", vault .. "/.scripts/vault-review.py" },
						{ text = true }
					):wait()
					if res.code ~= 0 then
						vim.notify("vault-review: " .. (res.stderr or "failed"), vim.log.levels.ERROR)
						return
					end
					vim.cmd.edit(vim.fn.fnameescape(vim.trim(res.stdout)))
				end,
				desc = "Generate vault review",
			},
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
			picker = { name = "snacks.picker" },
			attachments = { folder = "Files" },
			ui = { enable = false },
			legacy_commands = false, -- Just to suppress the annoying warning every startup

			note_id_func = title_to_filename,

			-- keep basic frontmatter, just don't have `id`
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
				enabled = false, -- handled by obsidian-sync.nix systemd service
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
