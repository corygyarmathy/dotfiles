return {
	"mfussenegger/nvim-lint",
	opts = {
		linters = {
			["markdownlint-cli2"] = {
				-- Same canonical config as conform above (see #219).
				args = { "--config", vim.fn.expand("$HOME/.config/nvim/.markdownlint-cli2.yaml"), "--" },
			},
		},
	},
}
