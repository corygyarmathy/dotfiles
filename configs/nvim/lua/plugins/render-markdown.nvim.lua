return {
	"MeanderingProgrammer/render-markdown.nvim",
	---@module 'render-markdown'
	---@type render.md.UserConfig
	opts = {
		pipe_table = { cell = "trimmed" },
		quote = { repeat_linebreak = true },
		completions = { lsp = { enabled = true } },

		-- raw markup visible while editing, fully hidden when rendered
		win_options = {
			conceallevel = { default = 0, rendered = 3 },
			concealcursor = { default = "", rendered = "" },
		},

		link = {
			wiki = {
				conceal_destination = true, -- hide "Note Name|", show just the alias
				icon = "󱗖 ",
			},
		},
	},
}
