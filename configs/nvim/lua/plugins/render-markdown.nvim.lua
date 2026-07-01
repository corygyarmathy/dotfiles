return {
	"MeanderingProgrammer/render-markdown.nvim",
	---@module 'render-markdown'
	---@type render.md.UserConfig
	opts = {
		pipe_table = { cell = "trimmed" }, -- or "overlay" if table alignment matters more than conceal
		quote = { repeat_linebreak = true }, -- stops from clobbering first character in line wrapped-paragraph
		completions = { lsp = { enabled = true } },
		win_options = {
			conceallevel = { default = 0, rendered = 3 },
			concealcursor = { default = "", rendered = "" },
		},
		link = { wiki = { conceal_destination = true, icon = "󱗖 " } },
	},
}
