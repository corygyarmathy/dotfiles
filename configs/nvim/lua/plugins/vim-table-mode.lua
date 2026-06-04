return {
	"dhruvasagar/vim-table-mode",
	ft = "markdown",
	cmd = { "TableModeToggle", "TableModeRealign" },
	init = function()
		vim.g.table_mode_corner = "|" -- markdown-style corners
	end,
}
