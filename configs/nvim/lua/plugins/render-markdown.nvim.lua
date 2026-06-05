return {
	"MeanderingProgrammer/render-markdown.nvim",
	---@module 'render-markdown'
	---@type render.md.UserConfig
	opts = {
		pipe_table = { cell = "trimmed" }, -- or "overlay" if table alignment matters more than conceal
		pipe_table = { cell = "trimmed" },
		quote = { repeat_linebreak = false }, -- stops from clobbering first character in line wrapped-paragraph
		completions = { lsp = { enabled = true } },
		win_options = {
			conceallevel = { default = 0, rendered = 3 },
			concealcursor = { default = "", rendered = "" },
		},
		link = { wiki = { conceal_destination = true, icon = "󱗖 " } },
	},
}
