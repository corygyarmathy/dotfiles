return {
	"MeanderingProgrammer/render-markdown.nvim",
	---@module 'render-markdown'
	---@type render.md.UserConfig
	opts = {
		pipe_table = {
			cell = "trimmed", --Decrease column width
		},
		quote = {
			repeat_linebreak = true,
		},
		completions = {
			lsp = { enabled = true },
		},
	},
}
