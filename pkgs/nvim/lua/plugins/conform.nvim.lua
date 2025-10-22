return {
	"stevearc/conform.nvim",
	opts = {
		formatters_by_ft = {
			markdown = { "markdownlint-cli2" }, -- Replace prettier with markdownlint
		},
		formatters = {
			["markdownlint-cli2"] = {
				args = {
					"--config",
					vim.fn.expand("$HOME/.config/nvim/lua/plugins/.markdownlint-cli2.yaml"),
					"--fix",
					"$FILENAME",
				},
			},
		},
	},
}
