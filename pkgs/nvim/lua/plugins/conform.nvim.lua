return {
	"stevearc/conform.nvim",
	opts = {
		formatters = {
			["markdownlint-cli2"] = {
				command = "markdownlint-cli2",
				args = {
					"--config",
					vim.fn.expand("$HOME/.config/nvim/lua/plugins/.markdownlint-cli2.yaml"),
					"--fix",
					"$FILENAME",
				},
				stdin = false,
			},
		},
	},
}
