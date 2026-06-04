return {
	"MeanderingProgrammer/render-markdown.nvim",
	---@module 'render-markdown'
	---@type render.md.UserConfig
	opts = {
		pipe_table = { cell = "trimmed" }, -- or "overlay" if table alignment matters more than conceal
		quote = { repeat_linebreak = true },
		completions = { lsp = { enabled = true } },
		win_options = {
			conceallevel = { default = 0, rendered = 3 },
			concealcursor = { default = "", rendered = "" },
			-- wrapped quote/callout lines indent 2 cols instead of clobbering the first char
			showbreak = { default = "", rendered = "  " },
			breakindent = { default = false, rendered = true },
			breakindentopt = { default = "", rendered = "" },
		},
		link = { wiki = { conceal_destination = true, icon = "󱗖 " } },
	},
}
