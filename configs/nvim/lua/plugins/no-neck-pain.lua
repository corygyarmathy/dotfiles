return {
	"shortcuts/no-neck-pain.nvim",
	version = "*",
	cmd = { "NoNeckPain", "NoNeckPainResize" },
	opts = {
		width = 95, -- your max content width; tune 80–100
		autocmds = {
			enableOnVimEnter = false, -- we enable it per-note instead (below)
			skipEnteringNoNeckPainBuffer = true,
		},
		buffers = {
			wo = { fillchars = "eob: " }, -- hide the ~ in the padding columns
		},
	},
}
